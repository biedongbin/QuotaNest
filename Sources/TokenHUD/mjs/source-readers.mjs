// Read-only adapters that resolve an imported source record (A) into an in-memory
// credential snapshot for the HUD. This module never writes to A: no source file is
// modified, no database is opened read-write, and no credential is persisted.
// Behaviour mirrors Sources/TokenHUD/ImportedSource.swift and
// ProviderAuthentication.swift; accountIdentity/canonical JSON must stay byte-identical
// to Swift's JSONSerialization(.sortedKeys) output, including "/" -> "\/" escaping.
import { readFileSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const MAX_FILE_BYTES = 64 * 1024 * 1024;
const SQLITE_TIMEOUT_MS = 3000;

// Unicode Cc, the same set as Swift's CharacterSet.controlCharacters.
const CONTROL = /[\u0000-\u001F\u007F-\u009F]/;

const failure = (code, message) => {
  const error = new Error(message);
  error.code = code;
  return error;
};

const sha256 = (text) => createHash('sha256').update(text).digest('hex');

// ---------------------------------------------------------------------------
// Canonical JSON (Swift JSONSerialization .sortedKeys parity for identity hashes)
// ---------------------------------------------------------------------------

function encodeString(value) {
  let out = '"';
  for (const char of value) {
    switch (char) {
      case '"': out += '\\"'; break;
      case '\\': out += '\\\\'; break;
      case '/': out += '\\/'; break; // Foundation escapes forward slashes.
      case '\b': out += '\\b'; break;
      case '\f': out += '\\f'; break;
      case '\n': out += '\\n'; break;
      case '\r': out += '\\r'; break;
      case '\t': out += '\\t'; break;
      default: {
        const code = char.codePointAt(0);
        out += code < 0x20 ? '\\u' + code.toString(16).padStart(4, '0') : char;
      }
    }
  }
  return out + '"';
}

function encodeValue(value) {
  if (value === null || value === undefined) return 'null';
  switch (typeof value) {
    case 'string': return encodeString(value);
    case 'boolean': return value ? 'true' : 'false';
    case 'number':
      if (!Number.isFinite(value)) throw failure('source-format', '来源记录包含无法序列化的数值');
      return JSON.stringify(value);
    case 'object': {
      if (Array.isArray(value)) return '[' + value.map(encodeValue).join(',') + ']';
      const keys = Object.keys(value).filter(key => value[key] !== undefined).sort();
      return '{' + keys.map(key => encodeString(key) + ':' + encodeValue(value[key])).join(',') + '}';
    }
    default: throw failure('source-format', '来源记录包含无法序列化的字段');
  }
}

/** Deterministic compact JSON with sorted keys and Foundation-compatible escaping. */
export function canonicalJson(value) {
  return encodeValue(value);
}

/** Swift-identical digest of a source record's JSON object (informational; not a cache key). */
export function sourceRevision(object) {
  return sha256(canonicalJson(object));
}

/** Stable binding digest: same record identity + same source coordinates -> same value. */
export function bindingDigest(reference, record) {
  const binding = {
    v: 1,
    source: reference.source,
    recordId: reference.recordId,
    providerId: reference.providerId,
    collection: reference.collection ?? null,
    credentialProviderId: reference.credentialProviderId ?? null,
    identity: accountIdentity(record?.object ?? {}) ?? null,
  };
  return 'sha256:' + sha256(canonicalJson(binding));
}

// ---------------------------------------------------------------------------
// Path / value helpers (mirror ProviderAuthentication.value(at:))
// ---------------------------------------------------------------------------

/** Dot-path or JSON-pointer path lookup; embedded JSON strings are decoded one step. */
export function getPath(object, path) {
  if (!object || typeof path !== 'string' || !path) return undefined;
  const keys = path.startsWith('/')
    ? path.slice(1).split('/').map(key => key.replace(/~1/g, '/').replace(/~0/g, '~'))
    : path.split('.');
  let current = object;
  for (const key of keys) {
    if (current && typeof current === 'object' && !Array.isArray(current)) {
      current = current[key];
      continue;
    }
    if (typeof current === 'string') {
      try {
        const parsed = JSON.parse(current);
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
          current = parsed[key];
          continue;
        }
      } catch { /* Not an embedded JSON object. */ }
    }
    return undefined;
  }
  return current;
}

const string = (object, path) => {
  const value = getPath(object, path);
  return typeof value === 'string' ? value : undefined;
};

// ---------------------------------------------------------------------------
// Identity (must match ImportedSource.accountIdentity byte for byte)
// ---------------------------------------------------------------------------

function jwtObject(segment) {
  if (typeof segment !== 'string' || !segment) return null;
  const encoded = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = encoded + '='.repeat((4 - (encoded.length % 4)) % 4);
  try {
    const parsed = JSON.parse(Buffer.from(padded, 'base64').toString('utf8'));
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null;
  } catch { return null; }
}

function accountIdentifier(object) {
  for (const path of ['tokens.account_id', 'accountId', 'metadata.email', 'email']) {
    const value = string(object, path);
    if (value && value.length) return value;
  }
  return undefined;
}

/** Account evidence hash, deliberately separate from rotating access tokens. */
export function accountIdentity(object) {
  if (!object || typeof object !== 'object' || Array.isArray(object)) return undefined;
  const evidence = {};
  const account = accountIdentifier(object);
  if (account) evidence.account = account;
  const uid = string(object, 'uid');
  if (uid) evidence.uid = uid;
  for (const path of ['tokens.id_token', 'tokens.access_token', 'accessToken', 'jwt', 'refresh.jwt', 'access']) {
    const token = string(object, path);
    if (!token) continue;
    const parts = token.split('.');
    if (parts.length !== 3) continue;
    const claims = jwtObject(parts[1]);
    if (claims && typeof claims.sub === 'string' && claims.sub) {
      evidence.subject = claims.sub;
      break;
    }
  }
  if (!Object.keys(evidence).length) return undefined;
  return 'sha256:' + sha256(canonicalJson(evidence));
}

function verifyIdentity(reference, object) {
  if (typeof reference.identityAccount !== 'string' || !reference.identityAccount) return;
  if (accountIdentity(object) !== reference.identityAccount) {
    throw failure('source-identity', '来源账号身份已变化，需重新导入');
  }
}

// ---------------------------------------------------------------------------
// Reference validation and file access
// ---------------------------------------------------------------------------

function requireText(value, label, { allowSlash = true } = {}) {
  if (typeof value !== 'string' || !value || CONTROL.test(value) || (!allowSlash && value.includes('/'))) {
    throw failure('source-format', `来源引用缺少有效的${label}`);
  }
  return value;
}

function expandPath(raw) {
  const expanded = raw === '~' ? homedir() : raw.startsWith('~/') ? join(homedir(), raw.slice(2)) : raw;
  if (!isAbsolute(expanded)) throw failure('source-format', '来源引用必须使用绝对路径');
  return resolve(expanded);
}

function fileInfo(path) {
  let stat;
  try { stat = statSync(path); } catch { throw failure('source-missing', '来源文件不存在或不可读'); }
  if (!stat.isFile()) throw failure('source-missing', '来源路径不是文件');
  if (stat.size > MAX_FILE_BYTES) throw failure('source-format', '来源文件过大');
  return stat;
}

function readJsonFile(path) {
  fileInfo(path);
  let text;
  try { text = readFileSync(path, 'utf8'); } catch { throw failure('source-missing', '来源文件不存在或不可读'); }
  let parsed;
  try { parsed = JSON.parse(text); } catch { throw failure('source-format', '来源文件不是有效的 JSON'); }
  return parsed;
}

function readJsonObject(path, label) {
  const parsed = readJsonFile(path);
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw failure('source-format', `${label}格式无效`);
  }
  return parsed;
}

// ---------------------------------------------------------------------------
// Read-only SQLite (node:sqlite first, /usr/bin/sqlite3 -readonly fallback)
// ---------------------------------------------------------------------------

let sqliteBackend = 'auto';

/** Test hook: 'auto' (node:sqlite when available), 'node', or 'cli'. */
export function setSqliteBackend(mode) {
  if (!['auto', 'node', 'cli'].includes(mode)) throw failure('source-format', '无效的 SQLite 读取后端');
  sqliteBackend = mode;
}

export function currentSqliteBackend() {
  if (sqliteBackend !== 'auto') return sqliteBackend;
  return loadNodeSqlite() ? 'node' : 'cli';
}

function loadNodeSqlite() {
  try {
    const module = require('node:sqlite');
    return typeof module?.DatabaseSync === 'function' ? module : null;
  } catch { return null; }
}

function queryNode(module, path, sql, timeout) {
  let database;
  try {
    database = new module.DatabaseSync(path, { readOnly: true, timeout });
  } catch { throw failure('source-missing', '来源数据库读取失败或不可用'); }
  try {
    database.exec('PRAGMA query_only = ON');
    const rows = database.prepare(sql).all();
    return rows.map(row => ({ ...row }));
  } catch { throw failure('source-format', '来源数据库查询失败'); }
  finally { try { database.close(); } catch { /* already closed */ } }
}

function queryCli(path, sql) {
  let output;
  try {
    output = execFileSync(process.platform === 'darwin' ? '/usr/bin/sqlite3' : 'sqlite3', ['-readonly', '-json', '-cmd', '.timeout 1000', path, sql], {
      timeout: SQLITE_TIMEOUT_MS, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch { throw failure('source-missing', '来源数据库读取失败或不可用'); }
  try {
    const rows = JSON.parse(output || '[]');
    return Array.isArray(rows) ? rows : [];
  } catch { throw failure('source-format', '来源数据库返回格式无效'); }
}

function queryReadonly(path, sql) {
  if (!/^\s*select\b/i.test(sql)) throw failure('source-format', '来源数据库只允许只读查询');
  fileInfo(path);
  const backend = currentSqliteBackend();
  if (backend === 'node') {
    const module = loadNodeSqlite();
    if (!module) throw failure('source-format', '当前 Node 运行时不支持只读 SQLite');
    return queryNode(module, path, sql, SQLITE_TIMEOUT_MS);
  }
  return queryCli(path, sql);
}

const sqlLiteral = (value) => "'" + value.replace(/'/g, "''") + "'";

function sqliteRecord(path, sql, label) {
  const rows = queryReadonly(path, sql);
  if (!Array.isArray(rows) || rows.length !== 1) {
    throw failure('source-missing', `导入来源${label}已删除或不唯一`);
  }
  return rows[0];
}

// ---------------------------------------------------------------------------
// Magpie (JSON): logins / plugin-auth / providers (+ key slots)
// ---------------------------------------------------------------------------

function readMagpieLogins(reference, file) {
  if (basename(file) !== 'logins.json') {
    throw failure('source-format', 'Magpie 原生登录引用路径无效');
  }
  const records = readJsonFile(file);
  if (!Array.isArray(records)) throw failure('source-format', 'Magpie 原生登录列表格式无效');
  if (records.length > 100_000) throw failure('source-format', 'Magpie 原生登录列表过大');
  const matches = records.filter(item => item && typeof item === 'object' && item.id === reference.recordId);
  if (matches.length !== 1) throw failure('source-missing', 'Magpie 来源记录已删除或不唯一');
  const login = matches[0];
  if (login.agent !== reference.providerId) {
    throw failure('source-identity', 'Magpie 来源记录类型已变化，需重新导入');
  }
  const snapshot = login.auth;
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot) || !Object.keys(snapshot).length) {
    throw failure('source-format', '此 Magpie 原生登录没有可只读使用的内联授权快照');
  }
  verifyIdentity(reference, snapshot);
  return { mode: 'auth', object: snapshot, key: '', baseURL: '', protocol: 'openai' };
}

function readMagpiePluginAuth(reference, file) {
  if (basename(file) !== 'plugin-auth.json') {
    throw failure('source-format', 'Magpie 插件授权引用路径无效');
  }
  const records = readJsonObject(file, 'Magpie 插件授权文件');
  const credentialProvider = reference.credentialProviderId || reference.providerId;
  if (!(reference.recordId === credentialProvider || reference.recordId.startsWith(credentialProvider + '#'))) {
    throw failure('source-identity', 'Magpie 插件来源引用类型不一致');
  }
  const record = records[reference.recordId];
  if (!record || typeof record !== 'object' || Array.isArray(record)) {
    throw failure('source-missing', 'Magpie 来源记录已删除');
  }
  validateMagpiePlugin(reference, file, credentialProvider, reference.providerId, record);
  verifyIdentity(reference, record);
  switch (record.type) {
    case 'oauth': return { mode: 'auth', object: record, key: '', baseURL: '', protocol: 'openai' };
    case 'api': return { mode: 'apikey', object: record, key: string(record, 'key') ?? '', baseURL: '', protocol: 'openai' };
    default: throw failure('source-format', 'Magpie 来源认证类型不支持');
  }
}

function validateMagpiePlugin(reference, file, credentialProvider, expected, record) {
  const directory = dirname(file);
  const providers = readJsonObject(join(directory, 'providers.json'), 'Magpie 来源供应商列表');
  const list = Array.isArray(providers.providers) ? providers.providers : null;
  if (!list) throw failure('source-format', 'Magpie 来源供应商列表无效');
  const actual = list.filter(item => item && typeof item === 'object' && item.id === expected);
  if (actual.length !== 1 || !(expected === credentialProvider || expected === credentialProvider + '-plugin')) {
    throw failure('source-identity', 'Magpie 原供应商与插件身份映射已变化');
  }
  const cached = readJsonFile(join(directory, 'plugin-providers.json'));
  if (!Array.isArray(cached)) throw failure('source-format', 'Magpie 插件身份缓存格式无效');
  const owners = cached.filter(item => item && typeof item === 'object' && item.id === credentialProvider);
  if (owners.length !== 1) throw failure('source-identity', 'Magpie 插件身份映射不唯一或已删除');
  const accounts = Array.isArray(owners[0].accounts) ? owners[0].accounts : [];
  const matches = accounts.filter(item => item && typeof item === 'object' && item.key === reference.recordId);
  if (matches.length !== 1) throw failure('source-identity', 'Magpie 插件来源账号已删除或归属变化');
  const accountId = matches[0].accountId;
  if (typeof accountId === 'string' && accountId && accountId !== accountIdentifier(record)) {
    throw failure('source-identity', 'Magpie 插件缓存与授权快照的账号身份不一致');
  }
  if (typeof matches[0].type === 'string' && matches[0].type !== record.type) {
    throw failure('source-identity', 'Magpie 插件缓存与授权快照的认证类型不一致');
  }
}

const ENDPOINTS = ['chat', 'responses', 'anthropic'];

function readMagpieProviders(reference, file, collection) {
  if (basename(file) !== 'providers.json') {
    throw failure('source-format', 'Magpie 来源供应商引用路径无效');
  }
  if (reference.recordId !== reference.providerId) {
    throw failure('source-format', 'Magpie 来源记录与供应商类型不一致');
  }
  const data = readJsonObject(file, 'Magpie 来源引用');
  if (!Array.isArray(data.providers)) throw failure('source-format', 'Magpie 来源引用格式无效');
  const matches = data.providers.filter(item => item && typeof item === 'object' && item.id === reference.providerId);
  if (matches.length !== 1) throw failure('source-missing', 'Magpie 来源记录已删除或不唯一');
  const record = matches[0];
  let key = '';
  let keyProtocol = '';
  if (collection === 'providers') {
    key = string(record, 'key') ?? '';
    keyProtocol = string(record, 'keyProtocol') ?? '';
  } else {
    const fingerprint = collection.slice('providers:key:'.length);
    if (!fingerprint) throw failure('source-format', 'Magpie 来源 Key 槽引用无效');
    const keys = Array.isArray(record.keys) ? record.keys : [];
    const matching = keys.filter(item => item && typeof item === 'object'
      && typeof item.key === 'string' && sha256(item.key).slice(0, 10) === fingerprint);
    if (matching.length !== 1) throw failure('source-missing', 'Magpie 来源 Key 已删除或变化');
    key = matching[0].key;
    keyProtocol = string(matching[0], 'protocol') ?? '';
  }
  const selection = keyProtocol || string(record, 'baseAPI') || '';
  const selected = selection === 'openai' ? 'chat' : selection;
  const candidates = selected ? [selected] : ENDPOINTS;
  const endpoint = candidates.find(name => ENDPOINTS.includes(name)
    && typeof record[name] === 'string' && record[name].length > 0);
  if (!endpoint) throw failure('source-format', 'Magpie 来源缺少受支持模型接口');
  verifyIdentity(reference, record);
  return {
    mode: 'apikey', object: record, key,
    baseURL: record[endpoint],
    protocol: endpoint === 'chat' ? 'openai' : endpoint,
  };
}

function readMagpie(reference, file) {
  const collection = reference.collection;
  if (collection === 'logins') return readMagpieLogins(reference, file);
  if (collection === 'plugin-auth') return readMagpiePluginAuth(reference, file);
  if (collection === 'providers' || (typeof collection === 'string' && collection.startsWith('providers:key:'))) {
    return readMagpieProviders(reference, file, collection);
  }
  throw failure('source-unsupported', '此 Magpie 来源类型暂不支持 HUD 直接读取');
}

// ---------------------------------------------------------------------------
// 9router / cc-switch (SQLite, read-only)
// ---------------------------------------------------------------------------

function read9router(reference, file) {
  const row = sqliteRecord(
    file,
    `SELECT provider, authType, data FROM providerConnections WHERE id = ${sqlLiteral(reference.recordId)} LIMIT 2`,
    '记录',
  );
  if (row.provider !== reference.providerId) {
    throw failure('source-identity', '导入来源供应商类型已变化，请重新导入');
  }
  if (typeof row.data !== 'string') throw failure('source-format', '导入来源记录缺少 JSON');
  let object;
  try {
    object = JSON.parse(row.data);
  } catch { throw failure('source-format', '导入来源记录缺少 JSON'); }
  if (!object || typeof object !== 'object' || Array.isArray(object)) {
    throw failure('source-format', '导入来源记录缺少 JSON');
  }
  object.provider = reference.providerId;
  object.authType = row.authType;
  const mode = row.authType === 'oauth' ? 'auth' : 'apikey';
  const key = string(object, 'apiKey') ?? '';
  const specific = object.providerSpecificData && typeof object.providerSpecificData === 'object'
    && !Array.isArray(object.providerSpecificData) ? object.providerSpecificData : {};
  const baseURL = string(specific, 'baseUrl') ?? string(object, 'baseUrl') ?? '';
  const protocol = reference.providerId.startsWith('anthropic') ? 'anthropic' : 'openai';
  verifyIdentity(reference, object);
  return { mode, object, key, baseURL, protocol };
}

function readCCSwitch(reference, file) {
  const row = sqliteRecord(
    file,
    `SELECT app_type, settings_config FROM providers WHERE id = ${sqlLiteral(reference.recordId)} AND app_type = ${sqlLiteral(reference.providerId)} LIMIT 2`,
    '记录',
  );
  if (row.app_type !== reference.providerId) {
    throw failure('source-identity', '导入来源记录类型已变化，请重新导入');
  }
  if (reference.providerId !== 'claude') {
    throw failure('source-unsupported', '此 cc-switch 来源类型尚未提供只读接入适配');
  }
  if (typeof row.settings_config !== 'string') throw failure('source-format', '导入来源记录缺少 JSON');
  let object;
  try {
    object = JSON.parse(row.settings_config);
  } catch { throw failure('source-format', '导入来源记录缺少 JSON'); }
  if (!object || typeof object !== 'object' || Array.isArray(object)) {
    throw failure('source-format', '导入来源记录缺少 JSON');
  }
  const env = object.env && typeof object.env === 'object' && !Array.isArray(object.env) ? object.env : {};
  const key = string(env, 'ANTHROPIC_AUTH_TOKEN') ?? string(env, 'ANTHROPIC_API_KEY') ?? '';
  const baseURL = string(env, 'ANTHROPIC_BASE_URL') ?? '';
  verifyIdentity(reference, object);
  return { mode: 'apikey', object, key, baseURL, protocol: 'anthropic' };
}

// ---------------------------------------------------------------------------
// CPAMP (single JSON auth file)
// ---------------------------------------------------------------------------

function readCPAMP(reference, file) {
  if (basename(file) !== reference.recordId) {
    throw failure('source-format', '导入来源文件名与记录不一致');
  }
  const object = readJsonObject(file, 'CPA 来源文件');
  if (object.type !== reference.providerId) {
    throw failure('source-identity', '导入来源供应商类型已变化，请重新导入');
  }
  const key = string(object, 'api_key') ?? '';
  const mode = key.length ? 'apikey' : 'auth';
  const baseURL = string(object, 'base_url') ?? '';
  const protocol = ['cline-pass', 'clinepass', 'claude'].includes(reference.providerId) ? 'anthropic' : 'responses';
  verifyIdentity(reference, object);
  return { mode, object, key, baseURL, protocol };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Resolve a source reference into an in-memory credential record.
 * @returns {{mode: 'auth'|'apikey', object: object, key: string, baseURL: string, protocol: string}}
 */
export function readReference(reference) {
  if (!reference || typeof reference !== 'object' || Array.isArray(reference)) {
    throw failure('source-format', '来源引用缺少路径、记录或类型');
  }
  requireText(reference.source, '来源类型');
  requireText(reference.recordId, '来源记录');
  requireText(reference.providerId, '来源供应商类型');
  const file = expandPath(requireText(reference.path, '来源路径'));
  if (reference.collection != null) requireText(reference.collection, '来源集合');
  if (reference.credentialProviderId != null) requireText(reference.credentialProviderId, '来源凭据归属');
  if (reference.identityAccount != null) requireText(reference.identityAccount, '来源身份摘要');
  switch (reference.source) {
    case 'magpie': return readMagpie(reference, file);
    case '9router': return read9router(reference, file);
    case 'cc-switch': return readCCSwitch(reference, file);
    case 'cpamp': return readCPAMP(reference, file);
    default: throw failure('source-unsupported', '此来源类型暂不支持 HUD 直接读取');
  }
}

function validToken(value) {
  return typeof value === 'string' && value.trim().length > 0 && !CONTROL.test(value);
}

function contextValue(object, path) {
  const value = getPath(object, path);
  if (typeof value === 'string') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  return undefined;
}

function accepts(format, object) {
  const required = format && format.requiredValues && typeof format.requiredValues === 'object'
    ? format.requiredValues : {};
  if (!Object.entries(required).every(([path, value]) => string(object, path) === value)) return false;
  const token = string(object, format.tokenPath);
  if (!validToken(token)) return false;
  if (format.tokenEncoding == null) return true;
  if (format.tokenEncoding !== 'jwt') return false;
  const parts = token.split('.');
  return parts.length === 3 && parts.every(part => part.length > 0)
    && jwtObject(parts[0]) !== null && jwtObject(parts[1]) !== null;
}

/**
 * Apply the provider's declared credential formats to a resolved source record,
 * exactly like ProviderAuthentication.resolveCall does for a Hud/auth source.
 * `credential` may be `{formats: [...]}` or the formats array itself.
 * @returns {{key: string, headerPaths: Record<string,string>, authContext: Record<string,string>}}
 */
export function resolveCredential(record, credential) {
  if (!record || typeof record !== 'object' || Array.isArray(record)
      || !record.object || typeof record.object !== 'object' || Array.isArray(record.object)) {
    throw failure('source-format', '来源记录缺少可用的授权快照');
  }
  if (record.mode === 'apikey') {
    const key = typeof record.key === 'string' ? record.key.trim() : '';
    if (!key || CONTROL.test(key)) throw failure('source-format', '来源缺少可用的 API Key');
    return { key, headerPaths: {}, authContext: {} };
  }
  if (record.mode !== 'auth') throw failure('source-format', '来源认证模式必须是 Auth 或 API Key');
  const formats = Array.isArray(credential)
    ? credential
    : credential && Array.isArray(credential.formats) ? credential.formats : [];
  for (const format of formats) {
    if (!format || typeof format !== 'object' || !accepts(format, record.object)) continue;
    const key = string(record.object, format.tokenPath);
    const headerPaths = {};
    const authContext = {};
    for (const [name, path] of Object.entries(format.contextPaths || {})) {
      const value = contextValue(record.object, path);
      if (!value) continue;
      if (CONTROL.test(value)) throw failure('source-format', '授权身份字段格式无效，请重新登录');
      authContext[name] = value;
    }
    for (const [header, path] of Object.entries(format.headerPaths || {})) {
      const value = string(record.object, path);
      if (!value) continue;
      if (CONTROL.test(value)) throw failure('source-format', '授权身份字段格式无效，请重新登录');
      if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(header)) {
        throw failure('source-format', '授权请求头名称格式无效');
      }
      headerPaths[header] = value;
    }
    const sortedHeaders = {};
    for (const name of Object.keys(headerPaths).sort()) sortedHeaders[name] = headerPaths[name];
    return { key, headerPaths: sortedHeaders, authContext };
  }
  throw failure('source-format', '本机授权记录缺少受支持登录格式的有效访问令牌');
}
