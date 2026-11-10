import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, copyFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync, spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { accountIdentity } from '../Sources/TokenHUD/mjs/source-readers.mjs';
import { entryRevision } from '../Sources/TokenHUD/mjs/hud-runtime.mjs';

const sources = fileURLToPath(new URL('../Sources/TokenHUD/mjs/', import.meta.url));
const read = path => JSON.parse(readFileSync(path, 'utf8'));
const locked = path => existsSync(path) && readdirSync(path).some(name => name.endsWith('.claim'));
const write = (path, data) => writeFileSync(path, JSON.stringify(data));
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'hud-independent-test-'));
  t.after(() => { assert.ok(resolve(root).startsWith(resolve(tmpdir()) + '/hud-independent-test-')); rmSync(root, { recursive: true, force: true }); });
  const hud = join(root, 'hud');
  mkdirSync(join(hud, 'providers', 'fixture'), { recursive: true });
  for (const name of ['statusline.mjs', 'ref-usage-provider.mjs', 'source-readers.mjs', 'hud-runtime.mjs']) copyFileSync(join(sources, name), join(hud, name));
  const source = join(root, 'logins.json');
  const auth = { auth_mode: 'chatgpt', tokens: { access_token: 'fixture-token-A', account_id: 'fixture-account' } };
  write(source, [{ id: 'record', agent: 'codex', auth, seen: 'before' }]);
  const cache = join(hud, '.fixture-hud-cache.json');
  const appCache = join(hud, '.fixture-usage-cache.json');
  write(appCache, { generatedAt: 1, seven_day: { used_percentage: 99 }, owner: 'B' });
  const entry = { schemaVersion: 2, label: 'Fixture', source: 'cache', cache,
    fetch: join(hud, 'providers', 'fixture', 'fetch.sh'), buckets: { seven_day: '周' },
    reference: { source: 'magpie', path: source, recordId: 'record', providerId: 'codex', collection: 'logins', identityAccount: accountIdentity(auth) },
    credential: { formats: [{ tokenPath: 'tokens.access_token', requiredValues: { auth_mode: 'chatgpt' }, headerPaths: { 'chatgpt-account-id': 'tokens.account_id' } }] },
    query: { url: 'https://example.invalid/usage', headerTemplate: 'Authorization: Bearer <key>', authHeaderTemplate: 'Authorization: Bearer <key>', quotaMode: 'script', authMode: 'auth' },
  };
  write(join(hud, 'envs.json'), { _schemaVersion: 2, fixture: entry });
  write(join(root, 'settings.json'), { env: { ACCOUNT_ENVS: 'fixture' } });
  writeFileSync(entry.fetch, '#!/bin/zsh\nset -eu\n"$TOKENHUD_NODE" "$TOKENHUD_HUD_DIR/mock-provider.mjs"\n');
  write(join(hud, 'response.json'), { seven_day: { used_percentage: 73 }, generatedAt: Date.now() });
  writeFileSync(join(hud, 'mock-provider.mjs'), `import { readFileSync, writeFileSync, appendFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
const hud = process.env.TOKENHUD_HUD_DIR;
const response = JSON.parse(readFileSync(join(hud, 'response.json')));
const auth = JSON.parse(readFileSync(process.env.TOKENHUD_AUTH_FILE));
if (auth.queryKey !== response.expectedKey && response.expectedKey) process.exit(7);
if ((statSync(process.env.TOKENHUD_AUTH_FILE).mode & 0o777) !== 0o600) process.exit(8);
if ((statSync(dirname(process.env.TOKENHUD_AUTH_FILE)).mode & 0o777) !== 0o700) process.exit(9);
if (!auth.headers['chatgpt-account-id'] && response.expectAccount) process.exit(10);
appendFileSync(join(hud, 'calls.log'), 'call\\n');
if (response.changeSource) writeFileSync(response.changeSource.path, JSON.stringify(response.changeSource.value));
if (response.delay) await delay(response.delay);
process.stdout.write(response.malformed ? 'not json' : JSON.stringify(response));
`);
  const env = { ...process.env, CLAUDE_CONFIG_DIR: root, TOKENHUD_HUD_DIR: hud };
  const run = () => {
    const result = spawnSync(process.execPath, [join(hud, 'ref-usage-provider.mjs'), 'fixture'], { env, cwd: root, encoding: 'utf8', timeout: 5000 });
    assert.equal(result.status, 0, result.stderr || result.error?.message);
    assert.equal(result.stdout, '', 'worker never prints credentials');
    return read(cache);
  };
  const expire = () => { const c = read(cache); c.lastAttemptAt = Date.now() - 120_000; write(cache, c); };
  const render = () => {
    const result = spawnSync(process.execPath, [join(hud, 'statusline.mjs')], { env, cwd: root, input: '{}', encoding: 'utf8', timeout: 3000 });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.replace(/\x1b\[[0-9;]*m/g, '');
  };
  return { root, hud, source, auth, cache, appCache, entry, env, run, expire, render,
    calls: () => existsSync(join(hud, 'calls.log')) ? readFileSync(join(hud, 'calls.log'), 'utf8').trim().split('\n').length : 0,
    response: value => write(join(hud, 'response.json'), value),
  };
}

test('C queries A without any App configuration and owns a separate cache', t => {
  const f = fixture(t), sourceBytes = readFileSync(f.source), appBytes = readFileSync(f.appCache);
  f.response({ seven_day: { used_percentage: 73 }, expectedKey: 'fixture-token-A', expectAccount: true });
  const cache = f.run();
  assert.equal(cache.seven_day.used_percentage, 73);
  assert.equal(f.calls(), 1);
  assert.deepEqual(readFileSync(f.source), sourceBytes);
  assert.deepEqual(readFileSync(f.appCache), appBytes);
  assert.doesNotMatch(readFileSync(f.cache, 'utf8'), /fixture-token-A|fixture-account/);
  assert.match(f.render(), /73%/);
  assert.doesNotMatch(f.render(), /99%|来源变更/);
});

test('TTL throttles repeated renders and workers; unrelated A writes do not invalidate usage', t => {
  const f = fixture(t); f.run();
  const records = read(f.source); records[0].seen = 'after'; records.push({ id: 'other', agent: 'copilot' }); write(f.source, records);
  f.run(); f.render(); f.render();
  assert.equal(f.calls(), 1);
  assert.match(f.render(), /73%/);
  f.expire(); f.run();
  assert.equal(f.calls(), 2);
  assert.match(f.render(), /73%/);
});

test('same-account token rotation is read directly from A on the next query', t => {
  const f = fixture(t); f.run();
  const records = read(f.source); records[0].auth.tokens.access_token = 'fixture-token-B'; write(f.source, records);
  f.expire(); f.response({ seven_day: { used_percentage: 42 }, expectedKey: 'fixture-token-B' });
  assert.equal(f.run().seven_day.used_percentage, 42);
});

for (const kind of ['deleted', 'switched']) test(`${kind} source clears prior numbers without needing B`, t => {
  const f = fixture(t); f.run(); f.expire();
  if (kind === 'deleted') write(f.source, []);
  else { const records = read(f.source); records[0].auth.tokens.account_id = 'other-account'; write(f.source, records); }
  const cache = f.run();
  assert.equal(cache.error, kind === 'deleted' ? 'source-missing' : 'source-identity');
  assert.equal(cache.seven_day, undefined);
  assert.equal(f.calls(), 1);
  assert.doesNotMatch(f.render(), /73%/);
});

test('network failure retains same-account success time and numbers only', t => {
  const f = fixture(t), success = f.run(); f.expire();
  f.response({ error: 'network', detail: 'fixture-token-A', seven_day: { used_percentage: 99 } });
  const failed = f.run();
  assert.equal(failed.seven_day.used_percentage, 73);
  assert.equal(failed.generatedAt, success.generatedAt);
  assert.equal(failed.stale, true);
  assert.equal(failed.error, 'network');
  assert.doesNotMatch(readFileSync(f.cache, 'utf8'), /fixture-token-A/);
});

test('source change during a request rejects the late response', t => {
  const f = fixture(t); f.run(); f.expire();
  const records = read(f.source); records[0].auth.tokens.account_id = 'replacement';
  f.response({ seven_day: { used_percentage: 12 }, changeSource: { path: f.source, value: records } });
  const cache = f.run();
  assert.equal(cache.error, 'source-identity');
  assert.equal(cache.seven_day, undefined);
});

test('concurrent HUD workers run one request per account', async t => {
  const f = fixture(t); f.response({ seven_day: { used_percentage: 32 }, delay: 250 });
  const invoke = () => new Promise((done, reject) => {
    const child = spawn(process.execPath, [join(f.hud, 'ref-usage-provider.mjs'), 'fixture'], { env: f.env, stdio: 'ignore' });
    child.on('error', reject); child.on('exit', code => code === 0 ? done() : reject(new Error(`worker exit ${code}`)));
  });
  await Promise.all(Array.from({ length: 6 }, invoke));
  assert.equal(f.calls(), 1);
  assert.equal(read(f.cache).seven_day.used_percentage, 32);
  assert.equal(locked(`${f.cache}.lock`), false);
});

test('Claude Code render launches its own query on missing cache', async t => {
  const f = fixture(t);
  assert.match(f.render(), /加载中/);
  const deadline = Date.now() + 4000;
  while (Date.now() < deadline && (!existsSync(f.cache) || read(f.cache).querying || locked(`${f.cache}.lock`))) await delay(25);
  assert.equal(locked(`${f.cache}.lock`), false);
  assert.equal(read(f.cache).seven_day.used_percentage, 73);
  assert.match(f.render(), /73%/);
});

test('configuration re-export does not reuse prior quota or B cache', t => {
  const f = fixture(t); f.run();
  f.entry.label = 'New account';
  write(join(f.hud, 'envs.json'), { _schemaVersion: 2, fixture: f.entry });
  f.response({ seven_day: { used_percentage: 21 } });
  const cache = f.run();
  assert.equal(cache.configuration, entryRevision(f.entry));
  assert.equal(cache.seven_day.used_percentage, 21);
  assert.equal(read(f.appCache).seven_day.used_percentage, 99);
});

test('legacy dynamic projection asks for explicit export rather than consuming B data', t => {
  const f = fixture(t);
  write(join(f.hud, 'envs.json'), { fixture: { label: 'Legacy', cache: f.appCache, source: 'cache' } });
  assert.match(f.render(), /请重新写入 HUD/);
  assert.doesNotMatch(f.render(), /99%/);
  assert.equal(f.calls(), 0);
});

test('manual key export is self-contained and never reads the App auth file', t => {
  const f = fixture(t);
  delete f.entry.reference;
  f.entry.credential = { keyFile: join(f.hud, '.fixture-hud-auth.json') };
  f.entry.query.authMode = 'apikey';
  write(f.entry.credential.keyFile, { key: 'manual-key' });
  write(join(f.hud, 'envs.json'), { _schemaVersion: 2, fixture: f.entry });
  f.response({ seven_day: { used_percentage: 55 }, expectedKey: 'manual-key' });
  assert.equal(f.run().seven_day.used_percentage, 55);
});

test('standalone external Auth files are read directly after export', t => {
  const f = fixture(t);
  delete f.entry.reference;
  f.entry.credential.file = join(f.root, 'external-auth.json');
  write(f.entry.credential.file, f.auth);
  write(join(f.hud, 'envs.json'), { _schemaVersion: 2, fixture: f.entry });
  f.response({ seven_day: { used_percentage: 24 }, expectedKey: f.auth.tokens.access_token });
  assert.equal(f.run().seven_day.used_percentage, 24);
});

test('a crashed worker lock is recovered without B intervention', t => {
  const f = fixture(t);
  mkdirSync(`${f.cache}.lock`);
  write(join(`${f.cache}.lock`, 'owner.json'), { pid: 2147483647 });
  assert.equal(f.run().seven_day.used_percentage, 73);
  assert.equal(locked(`${f.cache}.lock`), false);
});

test('a late response cannot overwrite a newer explicit export', t => {
  const f = fixture(t); f.run(); f.expire();
  const replacement = { ...f.entry, label: 'Replacement', query: { ...f.entry.query, url: 'https://example.invalid/new-usage' } };
  f.response({ seven_day: { used_percentage: 1 }, changeSource: { path: join(f.hud, 'envs.json'), value: { _schemaVersion: 2, fixture: replacement } } });
  const old = f.run();
  assert.notEqual(old.configuration, entryRevision(replacement));
  assert.notEqual(old.seven_day?.used_percentage, 1);
  f.response({ seven_day: { used_percentage: 25 } });
  assert.equal(f.run().seven_day.used_percentage, 25);
});

test('provider process failure and malformed response become a visible throttled error', t => {
  const f = fixture(t); f.response({ malformed: true });
  assert.equal(f.run().error, 'parse');
  assert.match(f.render(), /用量响应无效/);
  f.expire(); f.response({ expectedKey: 'intentionally-wrong' });
  assert.equal(f.run().error, 'hud-spawn');
  assert.match(f.render(), /无法启动查询脚本/);
});

for (const field of ['providerSpecificData.accountId', 'account_id']) {
  for (const during of [false, true]) test(`workspace ${field} switch ${during ? 'during request' : 'before failure'} clears other workspace quota`, t => {
    const f = fixture(t);
    const token = 'e30.' + Buffer.from(JSON.stringify({ sub: 'same-user' })).toString('base64url') + '.sig';
    const auth = { accessToken: token, account_id: 'workspace-a', providerSpecificData: { accountId: 'workspace-a' } };
    write(f.source, [{ id: 'record', agent: 'codex', auth }]);
    f.entry.reference.identityAccount = accountIdentity(auth);
    f.entry.credential.formats = [{ tokenPath: 'accessToken', headerPaths: { 'chatgpt-account-id': field } }];
    write(join(f.hud, 'envs.json'), { fixture: f.entry });
    const before = f.run(); f.expire();
    const changed = [{ id: 'record', agent: 'codex', auth: { ...auth, account_id: 'workspace-b', providerSpecificData: { accountId: 'workspace-b' } } }];
    assert.equal(accountIdentity(changed[0].auth), accountIdentity(auth));
    if (during) f.response({ seven_day: { used_percentage: 22 }, changeSource: { path: f.source, value: changed } });
    else { write(f.source, changed); f.response({ error: 'network' }); }
    const result = f.run();
    assert.equal(result.error, during ? 'source-changed' : 'network');
    assert.equal(result.seven_day, undefined);
    if (!during) assert.notEqual(result.binding, before.binding);
  });
}

test('future attempt and success timestamps render stale and launch a new query', async t => {
  const f = fixture(t); f.run();
  const cache = read(f.cache); cache.lastAttemptAt = cache.generatedAt = Date.now() + 3600000; cache.stale = false; write(f.cache, cache);
  const output = f.render();
  assert.match(output, /73%\*/);
  const deadline = Date.now() + 4000;
  while (f.calls() < 2 && Date.now() < deadline) await delay(25);
  assert.equal(f.calls(), 2);
  while (read(f.cache).querying && Date.now() < deadline) await delay(25);
});
