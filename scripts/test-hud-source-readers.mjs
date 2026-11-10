// Offline regression for Sources/TokenHUD/mjs/source-readers.mjs.
// All fixtures are synthetic; no real credential, database or user file is read.
// Run: node --test scripts/test-hud-source-readers.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, mkdirSync, rmSync, readFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import {
  accountIdentity, canonicalJson, sourceRevision, bindingDigest,
  readReference, resolveCredential, setSqliteBackend, currentSqliteBackend,
} from '../Sources/TokenHUD/mjs/source-readers.mjs';

const require = createRequire(import.meta.url);
const sha256 = (text) => createHash('sha256').update(text).digest('hex');
const b64url = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
const jwt = (claims) => `${b64url({ alg: 'none', typ: 'JWT' })}.${b64url(claims)}.signature`;

const sqliteModule = (() => {
  try { return require('node:sqlite'); } catch { return null; }
})();
const DatabaseSync = sqliteModule ? sqliteModule.DatabaseSync : null;
const sqliteSkip = DatabaseSync ? false : 'node:sqlite unavailable in this Node runtime';

function workspace(t) {
  const root = mkdtempSync(join(tmpdir(), 'hud-source-readers-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

function writeJson(path, value) {
  writeFileSync(path, JSON.stringify(value));
  return path;
}

function expectCode(fn, code) {
  assert.throws(fn, (error) => {
    assert.equal(error.code, code, `expected ${code}, got ${error.code}: ${error.message}`);
    return true;
  });
}

function assertNoSecret(error, secret) {
  assert.ok(!String(error && error.message).includes(secret), 'error message leaked a credential');
}

// ---------------------------------------------------------------------------
// Identity / canonical JSON parity with Swift JSONSerialization(.sortedKeys)
// Expected digests were produced by the Swift implementation (parity probe).
// ---------------------------------------------------------------------------

test('accountIdentity matches Swift canonical JSON, including "/" escaping', () => {
  const slashUnicode = {
    uid: 'u-1',
    tokens: { account_id: 'a/b ~tilde ünïcode', id_token: jwt({ sub: 'user|x' }) },
  };
  assert.equal(accountIdentity(slashUnicode),
    'sha256:9977a56313f6350b2b092dfcd9d8b0f153dc25326cf1fde77f2df397e6ed3b64');

  const subjectWithSlash = {
    tokens: {
      account_id: '6159991c-d3c2-45a2-b410-5ae804383b4f',
      id_token: jwt({ sub: 'auth0|abc.def/ghi' }),
    },
  };
  assert.equal(accountIdentity(subjectWithSlash),
    'sha256:5c9d9abf806eeac04c1977c8a509b155be6ce07d27f6a6a90ea18bdff8c24c21');

  assert.equal(canonicalJson({ b: 'x/y', a: 'é' }), '{"a":"é","b":"x\\/y"}');
});

test('accountIdentity ignores rotating tokens and display-only fields', () => {
  const base = { tokens: { account_id: 'acct', access_token: jwt({ sub: 'sub-1', exp: 1 }) } };
  const rotated = { ...base, seen: '2026-11-09T00:00:00Z', plan: 'pro' };
  rotated.tokens = { ...base.tokens, access_token: jwt({ sub: 'sub-1', exp: 2 }) };
  assert.equal(accountIdentity(base), accountIdentity(rotated));
  rotated.tokens.access_token = jwt({ sub: 'other-sub' });
  assert.notEqual(accountIdentity(base), accountIdentity(rotated));
  assert.equal(accountIdentity({}), undefined);
  assert.equal(accountIdentity({ tokens: { access_token: 'not-a-jwt' } }), undefined);
});

// ---------------------------------------------------------------------------
// Reference shape validation
// ---------------------------------------------------------------------------

test('readReference rejects malformed references without touching disk', () => {
  expectCode(() => readReference(null), 'source-format');
  expectCode(() => readReference({}), 'source-format');
  expectCode(() => readReference({ source: 'magpie', path: '/tmp/x', recordId: 'r' }), 'source-format');
  expectCode(() => readReference({ source: 'magpie', path: 'relative.json', recordId: 'r', providerId: 'p' }), 'source-format');
  expectCode(() => readReference({ source: 'magpie', path: '/tmp/x\0y', recordId: 'r', providerId: 'p' }), 'source-format');
  expectCode(() => readReference({ source: 'magpie', path: '/tmp/x', recordId: 'r\u0000', providerId: 'p' }), 'source-format');
  expectCode(() => readReference({ source: 'unknown', path: '/tmp/x', recordId: 'r', providerId: 'p' }), 'source-unsupported');
  expectCode(() => readReference({
    source: 'magpie', path: '/tmp/x', recordId: 'r', providerId: 'p', identityAccount: 42,
  }), 'source-format');
});

// ---------------------------------------------------------------------------
// Magpie logins.json
// ---------------------------------------------------------------------------

function loginsFixture(root, records) {
  return writeJson(join(root, 'logins.json'), records);
}

function codexLogin(overrides = {}) {
  return {
    id: 'login-codex',
    agent: 'codex',
    seen: '2026-11-09T10:17:00Z',
    auth: { auth_mode: 'chatgpt', tokens: { account_id: 'acct-1', id_token: jwt({ sub: 'sub-1' }) } },
    ...overrides,
  };
}

function loginsRef(path, extra = {}) {
  return {
    source: 'magpie', path, recordId: 'login-codex', providerId: 'codex', collection: 'logins',
    ...extra,
  };
}

test('magpie logins: resolves inline auth snapshot and ignores unrelated rewrites', (t) => {
  const root = workspace(t);
  const path = loginsFixture(root, [
    codexLogin(),
    { id: 'login-zcode', agent: 'plugin:zcode', seen: '2026-11-09T10:00:00Z', auth: { type: 'oauth' } },
  ]);
  const reference = loginsRef(path, { identityAccount: accountIdentity(codexLogin().auth) });
  const first = readReference(reference);
  assert.equal(first.mode, 'auth');
  assert.equal(first.object.tokens.account_id, 'acct-1');
  assert.equal(first.key, '');
  assert.equal(first.protocol, 'openai');

  // Another record and this record's `seen` are rewritten: identity and result stay stable.
  writeJson(path, [
    codexLogin({ seen: '2026-11-09T11:00:00Z' }),
    { id: 'login-zcode', agent: 'plugin:zcode', seen: '2026-11-09T11:00:00Z', auth: { type: 'oauth' } },
  ]);
  const second = readReference(reference);
  assert.equal(accountIdentity(second.object), accountIdentity(first.object));
  assert.equal(bindingDigest(reference, second), bindingDigest(reference, first));
});

test('magpie logins: token rotation keeps identity, account switch is rejected or re-bound', (t) => {
  const root = workspace(t);
  const rotated = codexLogin();
  rotated.auth = {
    ...rotated.auth,
    tokens: { ...rotated.auth.tokens, access_token: jwt({ sub: 'sub-1', exp: 9 }) },
  };
  const path = loginsFixture(root, [rotated]);
  const identity = accountIdentity(rotated.auth);
  const reference = loginsRef(path, { identityAccount: identity });
  const record = readReference(reference);
  assert.equal(accountIdentity(record.object), identity);
  assert.notEqual(sourceRevision(rotated.auth), sourceRevision(codexLogin().auth));

  const switched = codexLogin();
  switched.auth = { auth_mode: 'chatgpt', tokens: { account_id: 'acct-2', id_token: jwt({ sub: 'sub-2' }) } };
  writeJson(path, [switched]);
  expectCode(() => readReference(reference), 'source-identity');

  const unbound = loginsRef(path);
  const rebound = readReference(unbound);
  assert.equal(rebound.object.tokens.account_id, 'acct-2');
  assert.notEqual(bindingDigest(unbound, rebound), bindingDigest(unbound, record));
});

test('magpie logins: deleted, duplicated, retyped or snapshot-less records fail closed', (t) => {
  const root = workspace(t);
  const path = loginsFixture(root, [codexLogin()]);
  const reference = loginsRef(path);
  readReference(reference);

  writeJson(path, [codexLogin({ agent: 'copilot' })]);
  expectCode(() => readReference(reference), 'source-identity');

  writeJson(path, [codexLogin({ auth: {} })]);
  expectCode(() => readReference(reference), 'source-format');

  writeJson(path, [codexLogin(), codexLogin()]);
  expectCode(() => readReference(reference), 'source-missing');

  writeJson(path, []);
  expectCode(() => readReference(reference), 'source-missing');

  rmSync(path);
  expectCode(() => readReference(reference), 'source-missing');
});

test('magpie logins: reading never rewrites the source file', (t) => {
  const root = workspace(t);
  const path = loginsFixture(root, [codexLogin()]);
  const before = readFileSync(path);
  readReference(loginsRef(path));
  readReference(loginsRef(path));
  assert.deepEqual(readFileSync(path), before);
});

test('magpie logins: filename and JSON shape are validated', (t) => {
  const root = workspace(t);
  const wrongName = writeJson(join(root, 'other.json'), [codexLogin()]);
  expectCode(() => readReference(loginsRef(wrongName)), 'source-format');

  const path = join(root, 'logins.json');
  writeFileSync(path, '{"not":"a list"}');
  expectCode(() => readReference(loginsRef(path)), 'source-format');

  writeFileSync(path, 'not json at all');
  expectCode(() => readReference(loginsRef(path)), 'source-format');
});

// ---------------------------------------------------------------------------
// Magpie plugin-auth.json (with identity mapping files)
// ---------------------------------------------------------------------------

function pluginFixture(root, record = {}) {
  const directory = join(root, 'magpie');
  mkdirSync(directory, { recursive: true });
  writeJson(join(directory, 'providers.json'), { providers: [{ id: 'zcode', name: 'ZCode' }] });
  writeJson(join(directory, 'plugin-providers.json'), [
    { id: 'zcode', accounts: [{ key: 'zcode#acct-1', accountId: 'user-1', type: 'oauth' }] },
  ]);
  const auth = {
    type: 'oauth',
    access: jwt({ sub: 'sub-zcode' }),
    accountId: 'user-1',
    ...record,
  };
  writeJson(join(directory, 'plugin-auth.json'), { 'zcode#acct-1': auth });
  return {
    directory,
    path: join(directory, 'plugin-auth.json'),
    reference: {
      source: 'magpie', path: join(directory, 'plugin-auth.json'), recordId: 'zcode#acct-1',
      providerId: 'zcode', collection: 'plugin-auth', credentialProviderId: 'zcode',
    },
    auth,
  };
}

test('magpie plugin-auth: oauth and api records resolve', (t) => {
  const root = workspace(t);
  const fixture = pluginFixture(root);
  const reference = { ...fixture.reference, identityAccount: accountIdentity(fixture.auth) };
  const record = readReference(reference);
  assert.equal(record.mode, 'auth');
  assert.equal(record.object.accountId, 'user-1');

  writeJson(join(fixture.directory, 'plugin-providers.json'), [
    { id: 'zcode', accounts: [{ key: 'zcode#acct-1', accountId: 'user-1', type: 'api' }] },
  ]);
  writeJson(fixture.path, { 'zcode#acct-1': { type: 'api', key: 'sk-fixture-plugin', accountId: 'user-1' } });
  const api = readReference({ ...fixture.reference, identityAccount: undefined });
  assert.equal(api.mode, 'apikey');
  assert.equal(api.key, 'sk-fixture-plugin');
});

test('magpie plugin-auth: identity mapping failures are rejected', (t) => {
  const root = workspace(t);
  const fixture = pluginFixture(root);
  readReference(fixture.reference);

  writeJson(join(fixture.directory, 'plugin-providers.json'), [{ id: 'zcode', accounts: [] }]);
  expectCode(() => readReference(fixture.reference), 'source-identity');

  writeJson(join(fixture.directory, 'plugin-providers.json'), [
    { id: 'zcode', accounts: [{ key: 'zcode#acct-1', accountId: 'someone-else', type: 'oauth' }] },
  ]);
  expectCode(() => readReference(fixture.reference), 'source-identity');

  writeJson(join(fixture.directory, 'plugin-providers.json'), [
    { id: 'zcode', accounts: [{ key: 'zcode#acct-1', accountId: 'user-1', type: 'api' }] },
  ]);
  expectCode(() => readReference(fixture.reference), 'source-identity');

  writeJson(join(fixture.directory, 'providers.json'), { providers: [] });
  expectCode(() => readReference(fixture.reference), 'source-identity');
});

test('magpie plugin-auth: record deletion, prefix and filename are validated', (t) => {
  const root = workspace(t);
  const fixture = pluginFixture(root);

  writeJson(fixture.path, {});
  expectCode(() => readReference(fixture.reference), 'source-missing');

  writeJson(fixture.path, { 'zcode#acct-1': { type: 'api', key: 'sk-fixture-plugin' } });
  const wrongPrefix = { ...fixture.reference, recordId: 'other#acct-1' };
  expectCode(() => readReference(wrongPrefix), 'source-identity');

  const wrongName = { ...fixture.reference, path: join(root, 'not-plugin-auth.json') };
  expectCode(() => readReference(wrongName), 'source-format');
});

// ---------------------------------------------------------------------------
// Magpie providers.json + key slots
// ---------------------------------------------------------------------------

function providersFixture(root, providers) {
  return writeJson(join(root, 'providers.json'), { providers });
}

test('magpie providers: primary key and key slot resolve with endpoint selection', (t) => {
  const root = workspace(t);
  const path = providersFixture(root, [
    { id: 'p-anthropic', key: 'sk-primary', keyProtocol: 'anthropic', anthropic: 'https://anthropic.example' },
    {
      id: 'p-slot', keys: [{ key: 'sk-slot', protocol: 'responses' }],
      responses: 'https://responses.example', baseAPI: 'anthropic',
    },
  ]);
  const primary = readReference({
    source: 'magpie', path, recordId: 'p-anthropic', providerId: 'p-anthropic', collection: 'providers',
  });
  assert.equal(primary.mode, 'apikey');
  assert.equal(primary.key, 'sk-primary');
  assert.equal(primary.baseURL, 'https://anthropic.example');
  assert.equal(primary.protocol, 'anthropic');

  const fingerprint = sha256('sk-slot').slice(0, 10);
  const slot = readReference({
    source: 'magpie', path, recordId: 'p-slot', providerId: 'p-slot',
    collection: 'providers:key:' + fingerprint,
  });
  assert.equal(slot.key, 'sk-slot');
  assert.equal(slot.baseURL, 'https://responses.example');
  assert.equal(slot.protocol, 'responses');
});

test('magpie providers: key slot, record identity and endpoint failures fail closed', (t) => {
  const root = workspace(t);
  const path = providersFixture(root, [
    { id: 'p', keys: [{ key: 'sk-slot' }], responses: 'https://responses.example' },
    { id: 'p-empty', baseAPI: 'chat' },
  ]);
  const ref = (recordId, providerId, collection) => ({ source: 'magpie', path, recordId, providerId, collection });

  expectCode(() => readReference(ref('p', 'p', 'providers:key:' + '0000000000')), 'source-missing');
  expectCode(() => readReference(ref('missing', 'missing', 'providers')), 'source-missing');
  const emptyPrimary = readReference(ref('p', 'p', 'providers'));
  assert.equal(emptyPrimary.key, '');
  assert.equal(emptyPrimary.protocol, 'responses');
  expectCode(() => resolveCredential(emptyPrimary, []), 'source-format');
  expectCode(() => readReference(ref('p', 'p-empty', 'providers')), 'source-format');
  expectCode(() => readReference(ref('p-empty', 'p-empty', 'providers')), 'source-format');

  writeJson(path, { providers: 'not-a-list' });
  expectCode(() => readReference(ref('p', 'p', 'providers')), 'source-format');
});

// ---------------------------------------------------------------------------
// 9router SQLite (read-only, WAL, both backends)
// ---------------------------------------------------------------------------

function nineRouterFixture(root, rows, { wal = false } = {}) {
  const path = join(root, '9router.sqlite');
  const database = new DatabaseSync(path);
  if (wal) database.exec('PRAGMA journal_mode = WAL');
  database.exec('CREATE TABLE providerConnections (id TEXT PRIMARY KEY, provider TEXT, authType TEXT, data TEXT)');
  for (const row of rows) {
    database.prepare('INSERT INTO providerConnections VALUES (?, ?, ?, ?)')
      .run(row.id, row.provider, row.authType, JSON.stringify(row.data));
  }
  return { path, database };
}

function nineRouterRef(path, extra = {}) {
  return {
    source: '9router', path, recordId: 'conn-1', providerId: 'openai', collection: 'providerConnections',
    ...extra,
  };
}

test('9router: resolves API key and OAuth records with base URL', { skip: sqliteSkip }, (t) => {
  const root = workspace(t);
  const fixture = nineRouterFixture(root, [
    {
      id: 'conn-1', provider: 'openai', authType: 'apikey',
      data: { apiKey: 'sk-fixture-9router', providerSpecificData: { baseUrl: 'https://gateway.example' } },
    },
  ]);
  const record = readReference(nineRouterRef(fixture.path));
  assert.equal(record.mode, 'apikey');
  assert.equal(record.key, 'sk-fixture-9router');
  assert.equal(record.baseURL, 'https://gateway.example');
  assert.equal(record.protocol, 'openai');
  assert.equal(record.object.provider, 'openai');
  assert.equal(record.object.authType, 'apikey');
  fixture.database.close();
});

test('9router: missing, retyped and malformed records fail closed', { skip: sqliteSkip }, (t) => {
  const root = workspace(t);
  const fixture = nineRouterFixture(root, [
    { id: 'conn-1', provider: 'anthropic', authType: 'oauth', data: { apiKey: '' } },
  ]);
  expectCode(() => readReference(nineRouterRef(fixture.path)), 'source-identity');

  const oauth = readReference(nineRouterRef(fixture.path, { providerId: 'anthropic' }));
  assert.equal(oauth.mode, 'auth');
  assert.equal(oauth.protocol, 'anthropic');

  expectCode(() => readReference(nineRouterRef(fixture.path, { recordId: 'missing' })), 'source-missing');

  fixture.database.exec("UPDATE providerConnections SET data = 'not-json' WHERE id = 'conn-1'");
  expectCode(() => readReference(nineRouterRef(fixture.path, { providerId: 'anthropic' })), 'source-format');
  fixture.database.close();
});

test('9router: WAL database is read without writing A (node and cli backends)', { skip: sqliteSkip }, (t) => {
  const root = workspace(t);
  const fixture = nineRouterFixture(root, [
    { id: 'conn-1', provider: 'openai', authType: 'apikey', data: { apiKey: 'sk-fixture-wal' } },
  ], { wal: true });
  const databasePath = fixture.path;
  const walPath = databasePath + '-wal';
  const snapshot = () => ({
    database: readFileSync(databasePath).toString('base64'),
    wal: readFileSync(walPath).toString('base64'),
    files: readdirSync(root).filter(name => name.startsWith('9router.sqlite')).sort(),
  });
  const before = snapshot();
  try {
    assert.equal(readReference(nineRouterRef(databasePath)).key, 'sk-fixture-wal');
    setSqliteBackend('cli');
    assert.equal(readReference(nineRouterRef(databasePath)).key, 'sk-fixture-wal');
  } finally {
    setSqliteBackend('auto');
  }
  const after = snapshot();
  assert.deepEqual(after, before, 'read-only SQLite must not modify the database or WAL');
  assert.deepEqual(after.files, ['9router.sqlite', '9router.sqlite-shm', '9router.sqlite-wal']);
  fixture.database.close();
});

test('currentSqliteBackend reports the effective backend', () => {
  setSqliteBackend('auto');
  assert.ok(['node', 'cli'].includes(currentSqliteBackend()));
  setSqliteBackend('cli');
  assert.equal(currentSqliteBackend(), 'cli');
  setSqliteBackend('auto');
});

// ---------------------------------------------------------------------------
// cc-switch SQLite
// ---------------------------------------------------------------------------

function ccSwitchFixture(root, rows) {
  const path = join(root, 'cc-switch.db');
  const database = new DatabaseSync(path);
  database.exec('CREATE TABLE providers (id TEXT, app_type TEXT, settings_config TEXT, PRIMARY KEY(id, app_type))');
  for (const row of rows) {
    database.prepare('INSERT INTO providers VALUES (?, ?, ?)')
      .run(row.id, row.app_type, JSON.stringify(row.settings_config));
  }
  return { path, database };
}

test('cc-switch: claude settings resolve to an anthropic credential', { skip: sqliteSkip }, (t) => {
  const root = workspace(t);
  const fixture = ccSwitchFixture(root, [{
    id: 'claude-1', app_type: 'claude',
    settings_config: { env: { ANTHROPIC_AUTH_TOKEN: 'sk-fixture-cc', ANTHROPIC_BASE_URL: 'https://cc.example' } },
  }]);
  const reference = {
    source: 'cc-switch', path: fixture.path, recordId: 'claude-1', providerId: 'claude', collection: 'claude',
  };
  const record = readReference(reference);
  assert.equal(record.mode, 'apikey');
  assert.equal(record.key, 'sk-fixture-cc');
  assert.equal(record.baseURL, 'https://cc.example');
  assert.equal(record.protocol, 'anthropic');

  expectCode(() => readReference({ ...reference, recordId: 'missing' }), 'source-missing');
  expectCode(() => readReference({ ...reference, providerId: 'codex' }), 'source-missing');
  fixture.database.close();
});

test('cc-switch: unsupported app type is explicit', { skip: sqliteSkip }, (t) => {
  const root = workspace(t);
  const fixture = ccSwitchFixture(root, [{
    id: 'codex-1', app_type: 'codex', settings_config: { env: { OPENAI_API_KEY: 'sk-fixture-codex' } },
  }]);
  expectCode(() => readReference({
    source: 'cc-switch', path: fixture.path, recordId: 'codex-1', providerId: 'codex', collection: 'codex',
  }), 'source-unsupported');
  fixture.database.close();
});

// ---------------------------------------------------------------------------
// CPAMP JSON
// ---------------------------------------------------------------------------

test('cpamp: api_key records map to provider protocol', (t) => {
  const root = workspace(t);
  const path = writeJson(join(root, 'cline.json'), {
    type: 'clinepass', api_key: 'sk-fixture-cpamp', base_url: 'https://cpamp.example', model: 'm',
  });
  const reference = {
    source: 'cpamp', path, recordId: 'cline.json', providerId: 'clinepass', collection: 'auth-files',
  };
  const record = readReference(reference);
  assert.equal(record.mode, 'apikey');
  assert.equal(record.key, 'sk-fixture-cpamp');
  assert.equal(record.baseURL, 'https://cpamp.example');
  assert.equal(record.protocol, 'anthropic');

  const other = writeJson(join(root, 'other.json'), { type: 'openai-compatible', api_key: 'sk-2', base_url: 'https://x' });
  const second = readReference({ ...reference, path: other, recordId: 'other.json', providerId: 'openai-compatible' });
  assert.equal(second.protocol, 'responses');

  const authFile = writeJson(join(root, 'auth.json'), { type: 'claude', base_url: 'https://x' });
  const authRecord = readReference({ ...reference, path: authFile, recordId: 'auth.json', providerId: 'claude' });
  assert.equal(authRecord.mode, 'auth');
  assert.equal(authRecord.protocol, 'anthropic');
});

test('cpamp: filename, type and JSON failures fail closed', (t) => {
  const root = workspace(t);
  const path = writeJson(join(root, 'cline.json'), { type: 'clinepass', api_key: 'sk-fixture-cpamp' });
  const reference = {
    source: 'cpamp', path, recordId: 'cline.json', providerId: 'clinepass', collection: 'auth-files',
  };
  readReference(reference);

  expectCode(() => readReference({ ...reference, recordId: 'other.json' }), 'source-format');
  expectCode(() => readReference({ ...reference, providerId: 'claude' }), 'source-identity');

  writeFileSync(path, '{"broken":');
  expectCode(() => readReference(reference), 'source-format');
});

// ---------------------------------------------------------------------------
// resolveCredential (mirror ProviderAuthentication.resolveCall)
// ---------------------------------------------------------------------------

function authRecord(object, extra = {}) {
  return { mode: 'auth', object, key: '', baseURL: '', protocol: 'openai', ...extra };
}

test('resolveCredential: apikey trims and rejects control characters', () => {
  assert.equal(resolveCredential({ mode: 'apikey', object: {}, key: '  sk-trim  ' }).key, 'sk-trim');
  assert.deepEqual(resolveCredential({ mode: 'apikey', object: {}, key: 'sk-plain' }).headerPaths, {});
  expectCode(() => resolveCredential({ mode: 'apikey', object: {}, key: '   ' }), 'source-format');
  expectCode(() => resolveCredential({ mode: 'apikey', object: {}, key: 'sk\r\nX-Injected: y' }), 'source-format');
});

test('resolveCredential: format selection honours requiredValues and JWT encoding', () => {
  const token = jwt({ sub: 'user' });
  const object = {
    auth_mode: 'chatgpt', n: 42,
    tokens: { access_token: token, account_id: 'acct-9' },
  };
  const formats = [
    { name: 'other', tokenPath: 'tokens.access_token', requiredValues: { auth_mode: 'api' } },
    {
      name: 'primary', tokenPath: 'tokens.access_token', requiredValues: { auth_mode: 'chatgpt' },
      tokenEncoding: 'jwt',
      headerPaths: { 'chatgpt-account-id': 'tokens.account_id', 'X-Numeric': 'n' },
      contextPaths: { workspace: 'n' },
    },
  ];
  const resolved = resolveCredential(authRecord(object), { formats });
  assert.equal(resolved.key, token);
  assert.deepEqual(resolved.headerPaths, { 'chatgpt-account-id': 'acct-9' });
  assert.deepEqual(resolved.authContext, { workspace: '42' });
});

test('resolveCredential: rejects control characters in headers/context and bad header names', () => {
  const token = jwt({ sub: 'user' });
  const controlHeader = [{ tokenPath: 'tokens.access_token', headerPaths: { 'X-Account': 'tokens.account_id' } }];
  expectCode(() => resolveCredential(authRecord({
    tokens: { access_token: token, account_id: 'a\rb' },
  }), { formats: controlHeader }), 'source-format');

  const controlContext = [{ tokenPath: 'tokens.access_token', contextPaths: { account: 'tokens.account_id' } }];
  expectCode(() => resolveCredential(authRecord({
    tokens: { access_token: token, account_id: 'a\u0000b' },
  }), { formats: controlContext }), 'source-format');

  const badName = [{ tokenPath: 'tokens.access_token', headerPaths: { 'Bad Header': 'tokens.account_id' } }];
  expectCode(() => resolveCredential(authRecord({
    tokens: { access_token: token, account_id: 'acct' },
  }), { formats: badName }), 'source-format');
});

test('resolveCredential: jwt encoding requires a decodable token; empty formats fail closed', () => {
  const formats = [{ tokenPath: 'tokens.access_token', tokenEncoding: 'jwt' }];
  expectCode(() => resolveCredential(authRecord({ tokens: { access_token: 'opaque-token' } }), { formats }), 'source-format');
  expectCode(() => resolveCredential(authRecord({ tokens: { access_token: jwt({ sub: 'u' }) } }), { formats: [] }), 'source-format');
  expectCode(() => resolveCredential(authRecord({ tokens: {} }), { formats }), 'source-format');
});

test('reader errors never include credential material', (t) => {
  const root = workspace(t);
  const secret = 'sk-fixture-leak';
  const path = writeJson(join(root, 'logins.json'), [{
    id: 'login-codex', agent: 'copilot', auth: { api_key: secret },
  }]);
  try {
    readReference(loginsRef(path, { identityAccount: 'sha256:deadbeef' }));
    assert.fail('expected an error');
  } catch (error) {
    assertNoSecret(error, secret);
    assert.equal(error.code, 'source-identity');
  }
});

for (const backend of ['node', 'cli']) test(`cc-switch composite primary key selects claude only (${backend})`, { skip: sqliteSkip }, t => {
  const root = workspace(t);
  const f = ccSwitchFixture(root, [
    { id: "shared'id", app_type: 'claude', settings_config: { env: { ANTHROPIC_API_KEY: 'expected-key' } } },
    { id: "shared'id", app_type: 'codex', settings_config: { env: { OPENAI_API_KEY: 'wrong-key' } } },
  ]);
  f.database.close();
  const before = readFileSync(f.path);
  try {
    setSqliteBackend(backend);
    assert.equal(readReference({ source: 'cc-switch', path: f.path, recordId: "shared'id", providerId: 'claude' }).key, 'expected-key');
    assert.deepEqual(readFileSync(f.path), before);
  } finally { setSqliteBackend('auto'); }
});
