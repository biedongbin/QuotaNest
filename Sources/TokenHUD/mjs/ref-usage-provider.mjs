#!/usr/bin/env node
// C owns this worker: resolve A directly, query with the exported provider adapter,
// and publish only C's cache. No QuotaNest executable, state or timer is used.
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, chmodSync,
  renameSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { readReference, resolveCredential, accountIdentity } from './source-readers.mjs';
import { HUD_TTL_MS, digest, entryRevision, hudCachePath, attemptFresh, safeError, acquireLock } from './hud-runtime.mjs';

const HUD_DIR = resolve(process.env.TOKENHUD_HUD_DIR
  || join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'hud'));
const readJSON = path => { try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; } };
const fail = code => { throw Object.assign(new Error(code), { code }); };

function publish(path, value) {
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, JSON.stringify(value), { mode: 0o600 });
  renameSync(temporary, path);
}

function headersFrom(template, key) {
  const headers = {};
  for (const line of String(template || '').split('\n')) {
    if (!line.trim()) continue;
    const match = /^\s*([^:]+):\s*(.*?)\s*$/.exec(line);
    if (!match || !/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(match[1])) fail('hud-config');
    const value = match[2].replaceAll('<key>', key);
    if (/[\x00-\x1f\x7f]/.test(value)) fail('source-format');
    headers[match[1].toLowerCase()] = value;
  }
  return headers;
}

function resolveInput(entry) {
  let record;
  if (entry.reference) record = readReference(entry.reference);
  else if (entry.credential?.file) {
    const object = readJSON(entry.credential.file);
    if (!object) fail('source-missing');
    record = { mode: 'auth', object, key: '' };
  } else if (entry.credential?.keyFile) {
    const object = readJSON(entry.credential.keyFile);
    if (!object) fail('source-missing');
    record = { mode: 'apikey', object: {}, key: object.key };
  } else fail('no-auth');
  const query = entry.query || {};
  if (Array.isArray(query.quotaAuthModes) && !query.quotaAuthModes.includes(record.mode)) fail('no-query');
  if (query.queryAuth === 'header' && record.mode !== 'auth') fail('no-auth');
  const credential = resolveCredential(record, entry.credential);
  const template = record.mode === 'auth' ? query.authHeaderTemplate ?? query.headerTemplate : query.headerTemplate;
  const headers = headersFrom(template, credential.key);
  if (record.mode === 'auth' && query.inheritHeaders !== false) {
    for (const [name, value] of Object.entries(credential.headerPaths)) {
      if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name) || /[\x00-\x1f\x7f]/.test(value)) fail('source-format');
      headers[name.toLowerCase()] = value;
    }
  }
  const snapshot = {
    tokenhudResolvedAuth: true, authMode: record.mode,
    tokenhudAuthContext: credential.authContext,
    queryKey: credential.key, apiKey: credential.key, refreshApiKey: credential.key,
    apiUrl: query.url || '', queryUrl: query.url || '', quotaMode: query.quotaMode,
    headers, accountId: headers['chatgpt-account-id'],
  };
  if (query.keyField && !['__proto__', 'constructor', 'prototype'].includes(query.keyField)) snapshot[query.keyField] = credential.key;
  const identity = record.mode === 'auth' ? accountIdentity(record.object) : null;
  const binding = digest({ configuration: entryRevision(entry), identity: identity || digest(credential.key),
    requestAccount: headers['chatgpt-account-id'] || null });
  return { snapshot, binding, revision: digest(snapshot),
    secrets: [credential.key, ...Object.values(credential.headerPaths), ...Object.values(credential.authContext)] };
}

// Persist the standard usage fields only: no raw responses, source objects, tokens
// or provider diagnostics. Preserve success time when an attempt fails.
function usageOnly(raw, secrets) {
  const text = value => {
    if (typeof value !== 'string') return undefined;
    let result = value.replace(/[\x00-\x1f\x7f]/g, '').slice(0, 160);
    for (const secret of secrets) if (typeof secret === 'string' && secret.length >= 4) result = result.replaceAll(secret, '[redacted]');
    return result;
  };
  const bucket = value => {
    if (!value || typeof value !== 'object') return null;
    const output = {};
    for (const key of ['used_percentage', 'remaining_percentage', 'resets_at', 'amount', 'limit']) {
      if (Number.isFinite(value[key])) output[key] = value[key];
    }
    for (const key of ['label', 'period', 'unit']) {
      const clean = text(value[key]);
      if (clean) output[key] = clean;
    }
    return Object.keys(output).length ? output : null;
  };
  const result = {};
  for (const key of ['five_hour', 'seven_day', 'monthly']) {
    const value = bucket(raw?.[key]);
    if (value) result[key] = value;
  }
  if (Array.isArray(raw?.windows)) result.windows = raw.windows.slice(0, 100).map(bucket).filter(Boolean);
  return result;
}
const hasUsage = value => ['five_hour', 'seven_day', 'monthly'].some(key => value?.[key]) || value?.windows?.length > 0;

function main() {
  const slug = process.argv[2];
  let cachePath;
  try { cachePath = hudCachePath(HUD_DIR, slug); } catch { return; }
  const entry = readJSON(join(HUD_DIR, 'envs.json'))?.[slug];
  if (entry?.schemaVersion !== 2 || entry.source === 'api') return;
  const configuration = entryRevision(entry);
  const stillCurrent = () => {
    const current = readJSON(join(HUD_DIR, 'envs.json'))?.[slug];
    return current && entryRevision(current) === configuration;
  };
  const lock = `${cachePath}.lock`;
  mkdirSync(HUD_DIR, { recursive: true });
  const release = acquireLock(lock);
  if (!release) return;
  let temporary;
  try {
    const previous = readJSON(cachePath);
    if (previous?.configuration === configuration && attemptFresh(previous)) return;
    const stamp = { schemaVersion: 2, configuration, lastAttemptAt: Date.now(), ttlMs: HUD_TTL_MS };
    let input;
    const report = (code, keep = null) => {
      if (!stillCurrent()) return;
      publish(cachePath, { ...(keep || {}), ...stamp, error: safeError(code), stale: true });
    };
    try { input = resolveInput(entry); }
    catch (error) { report(error.code || 'source-format'); return; }
    stamp.binding = input.binding;
    const previousUsage = previous?.configuration === configuration && previous.binding === input.binding && hasUsage(previous)
      ? { ...usageOnly(previous, input.secrets), generatedAt: previous.generatedAt } : null;
    // Throttle repeats even on an interrupted process. Reading A failed above clears old identity data.
    if (!stillCurrent()) return;
    publish(cachePath, { ...(previousUsage || {}), ...stamp, stale: true, querying: true });
    if (entry.cache !== cachePath || typeof entry.fetch !== 'string') { report('hud-config'); return; }
    const fetchPath = resolve(entry.fetch);
    if (!fetchPath.startsWith(join(HUD_DIR, 'providers') + '/') || fetchPath === HUD_DIR) { report('hud-config'); return; }
    temporary = mkdtempSync(join(tmpdir(), 'hud-query-'));
    chmodSync(temporary, 0o700);
    const authFile = join(temporary, 'auth.json');
    const childCache = join(temporary, 'cache.json');
    writeFileSync(authFile, JSON.stringify(input.snapshot), { mode: 0o600 });
    if (previousUsage) writeFileSync(childCache, JSON.stringify(previousUsage), { mode: 0o600 });
    const environment = { ...process.env };
    // Ambient debug switches must not make provider adapters persist raw responses.
    delete environment.USAGE_DEBUG;
    delete environment.USAGE_VERBOSE;
    const run = spawnSync('/bin/zsh', [fetchPath], {
      cwd: dirname(fetchPath), timeout: 21_000, killSignal: 'SIGKILL', maxBuffer: 2_000_000,
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...environment, TOKENHUD_NODE: process.execPath, TOKENHUD_HUD_DIR: HUD_DIR,
        TOKENHUD_AUTH_FILE: authFile, USAGE_AUTH_FILE: authFile,
        TOKENHUD_CACHE_FILE: childCache, USAGE_CACHE_FILE: childCache,
        TOKENHUD_STDOUT_ONLY: '1', TOKENHUD_QUERY_URL: input.snapshot.queryUrl,
        TOKENHUD_QUOTA_MODE: entry.query?.quotaMode || '' },
    });
    if (!stillCurrent()) return;
    // Token changes during a request invalidate that response; unrelated A writes do not.
    let current;
    try { current = resolveInput(entry); }
    catch (error) { report(error.code || 'source-format'); return; }
    if (current.revision !== input.revision) {
      report('source-changed', current.binding === input.binding ? previousUsage : null); return;
    }
    if (run.error || run.status !== 0) { report('hud-spawn', previousUsage); return; }
    let raw;
    try { raw = JSON.parse(run.stdout.trim()); } catch { report('parse', previousUsage); return; }
    if (raw?.error) { report(raw.error, previousUsage); return; }
    const usage = usageOnly(raw, input.secrets);
    if (!hasUsage(usage)) { report('parse', previousUsage); return; }
    publish(cachePath, { ...usage, ...stamp, generatedAt: Date.now(), stale: false, error: null });
  } finally {
    if (temporary && dirname(temporary) === resolve(tmpdir()) && temporary.split('/').pop().startsWith('hud-query-')) {
      rmSync(temporary, { recursive: true, force: true });
    }
    release();
  }
}
try { main(); } catch { /* HUD must never print credentials or break the terminal. */ }
