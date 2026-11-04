#!/usr/bin/env node
// Offline wrapper contract: fake curl receives real argv, never contacts a vendor.
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, rmSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { communityProviders, parseCommunityUsage } from '../Sources/TokenHUD/mjs/catalog-community-provider.mjs';
import { normalizeUsage } from '../Sources/TokenHUD/mjs/usage-normalize.mjs';
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const temp = mkdtempSync(join(tmpdir(), 'tokenhud-community-'));
const hud = join(temp, 'hud');
mkdirSync(hud);
copyFileSync(join(repo, 'Sources/TokenHUD/mjs/catalog-community-provider.mjs'), join(hud, 'catalog-community-provider.mjs'));
const snapshotFile = join(temp, 'snapshot.json'), cacheFile = join(temp, 'cache.json'), originalFile = join(temp, 'original.json'), argsFile = join(temp, 'args.json');
const curl = join(temp, 'fake-curl.mjs');
writeFileSync(curl, `#!${process.execPath}\nimport {writeFileSync} from 'node:fs';\nwriteFileSync(process.env.FIXTURE_ARGS,JSON.stringify(process.argv.slice(2)));\nprocess.stdout.write(process.env.FIXTURE_BODY+'\\n'+process.env.FIXTURE_STATUS);\nprocess.exit(Number(process.env.FIXTURE_EXIT||0));\n`, { mode: 0o700 });
const original = '{"access":"sessionB","refresh":"refreshB","auth":{"accessToken":"sessionB"}}\n';
writeFileSync(originalFile, original);
const old = { apiKey: 'keyB', refreshApiKey: 'keyB', cookieAuth: 'old-cookieB', token: 'sessionB', queryUrl: 'https://attacker.invalid', externalAuthFile: originalFile, headers: { Authorization: 'Bearer keyB' } };
const fixtures = {
  factory: { limits: { standard: { fiveHour: { usedPercent: 20, windowEnd: 1800000000000 }, weekly: { usedPercent: 0 } }, core: { monthly: { usedPercent: 85, windowEnd: '2027-01-15T12:00:00Z' } } }, extraUsageBalanceCents: 1250 },
  'agnes-code': { code: '000000', data: { total_balance: 600, time_sensitive_balance: 500, permanent_balance: 100 } },
  catpaw: { code: 0, data: { availableCredits: 73, userPlan: { planName: 'Pro' } } },
  loomy: { code: '000000', data: { data: { dailyBalance: 90, dailyLimitPoints: 100, dailyRemainingPoints: 40, balance: 8 } } },
};
const modes = { factory: 'apikey', 'agnes-code': 'apikey', catpaw: 'auth', loomy: 'auth' };
let scenarios = 0;
function run(provider, body, { status = 200, exit = 0, auth = {}, stdoutOnly = true } = {}) {
  const snapshot = JSON.stringify({ ...old, authMode: modes[provider], queryKey: 'baseA', tokenhudAuthContext: { userId: 'userA' }, ...auth });
  writeFileSync(snapshotFile, snapshot);
  const cached = JSON.stringify({ generatedAt: 42, windows: [{ label: '上次余额', amount: 5, unit: 'credits', period: 'balance' }] });
  writeFileSync(cacheFile, cached);
  const wrapper = join(temp, 'fetch.sh');
  writeFileSync(wrapper, readFileSync(join(repo, `Sources/TokenHUD/providers/${provider}/fetch.sh`), 'utf8').replaceAll('{SLUG}', 'account-fixture'));
  const result = spawnSync('/bin/zsh', [wrapper], { encoding: 'utf8', timeout: 5000, env: {
    PATH: process.env.PATH, HOME: temp, TOKENHUD_NODE: process.execPath, TOKENHUD_HUD_DIR: hud,
    TOKENHUD_AUTH_FILE: snapshotFile, TOKENHUD_CACHE_FILE: cacheFile, TOKENHUD_STDOUT_ONLY: stdoutOnly ? '1' : '0', TOKENHUD_CURL: curl,
    TOKENHUD_QUERY_URL: 'https://attacker.invalid/env', FIXTURE_ARGS: argsFile,
    FIXTURE_BODY: typeof body === 'string' ? body : JSON.stringify(body), FIXTURE_STATUS: String(status), FIXTURE_EXIT: String(exit),
  } });
  assert.equal(result.status, 0, `${provider}: ${result.stderr}`);
  assert.equal(readFileSync(snapshotFile, 'utf8'), snapshot, 'snapshot bytes unchanged');
  assert.equal(readFileSync(originalFile, 'utf8'), original, 'external Auth bytes unchanged');
  const output = JSON.parse(result.stdout);
  if (stdoutOnly) assert.equal(readFileSync(cacheFile, 'utf8'), cached, 'stdout mode must not write cache');
  else assert.deepEqual(JSON.parse(readFileSync(cacheFile, 'utf8')), output);
  scenarios++;
  return output;
}
try {
  for (const [provider, body] of Object.entries(fixtures)) {
    const manifest = JSON.parse(readFileSync(join(repo, `Sources/TokenHUD/providers/${provider}/manifest.json`), 'utf8'));
    assert.equal(manifest.autoCreateDefault, false);
    assert.equal(manifest.quotaMode, 'script');
    assert.equal(manifest.inheritQueryUrl, communityProviders[provider].url);
    assert.equal(manifest.authMode, modes[provider]);
    assert.equal(manifest.queryAuth, modes[provider] === 'apikey' ? 'bearer' : 'header', 'core rejects header-only quota for API Key mode');
    assert.equal(manifest.refreshUrl, undefined, 'quota-only, no invented model endpoint');
    assert.equal(manifest.authCallUrl, undefined);
    assert.equal(manifest.testModel, '');
    if (provider === 'loomy' || provider === 'agnes-code') assert.equal(manifest.credentialSource.file, '');
    if (provider === 'catpaw') {
      assert.equal(manifest.credentialSource.file, '~/.meituan-catpaw/auth.json');
      assert.equal(manifest.credentialSource.tokenPath, 'auth.accessToken');
      assert.equal(manifest.credentialSource.contextPaths.userId, 'account.uid');
      assert.deepEqual(manifest.credentialSource.alternatives, [{ tokenPath: 'access', requiredValues: { type: 'oauth' } }]);
    }
    const output = run(provider, body);
    assert.equal(output.error, null);
    assert.equal(output.stale, false);
    assert.equal(normalizeUsage(output).windows.length, output.windows.length);
    const args = JSON.parse(readFileSync(argsFile, 'utf8'));
    assert.equal(args[0], '-q');
    assert.equal(args.at(-1), communityProviders[provider].url);
    assert.equal(args[args.indexOf('-X') + 1], 'GET');
    assert(!args.includes('--data-binary') && !args.includes('-d'), 'GET has no body');
    assert(!args.includes('-L') && !args.includes('--location'));
    assert.equal(args[args.indexOf('--proto') + 1], '=https');
    assert.equal(args[args.indexOf('--connect-timeout') + 1], '3');
    assert.equal(args[args.indexOf('--max-time') + 1], '12');
    assert(!JSON.stringify(args).includes('keyB') && !JSON.stringify(args).includes('sessionB') && !JSON.stringify(args).includes('cookieB'));
    if (provider === 'catpaw') {
      assert(args.includes('X-Auth-Token: baseA'));
      assert(args.includes('gray-set: new-agent-sdk'));
      assert(!args.some(value => /^(Authorization|Cookie):/i.test(value)));
    } else assert(args.includes('Authorization: Bearer baseA'));
    if (provider === 'loomy') assert(args.includes('token: baseA'));
    if (provider === 'factory') for (const h of ['X-Factory-Client: cli', 'X-Client-Version: 0.242.0', 'User-Agent: factory-cli/0.242.0']) assert(args.includes(h));
    assert.equal(run(provider, {}).error, 'parse');
    assert.equal(run(provider, '{broken').error, 'parse');
    for (const status of [401, 403, 301, 302, 303, 307, 308]) assert.equal(run(provider, body, { status }).error, 'auth');
    assert.equal(run(provider, body, { status: 429 }).error, 'ratelimit');
    assert.equal(run(provider, body, { status: 500 }).error, 'network');
    assert.equal(run(provider, body, { exit: 28 }).error, 'network');
    const marker = readFileSync(argsFile, 'utf8');
    for (const queryKey of ['', null, 'baseA\nInjected: yes']) assert.equal(run(provider, body, { auth: { queryKey } }).error, 'no-auth');
    assert.equal(readFileSync(argsFile, 'utf8'), marker, 'never reuse old query credentials or externalAuthFile');
    const failed = run(provider, {}, { stdoutOnly: false });
    assert.equal(failed.generatedAt, undefined, 'native engine owns last-good retention');
    assert.equal(failed.windows, undefined);
    assert.equal(failed.stale, true);
    run(provider, body, { stdoutOnly: false });
  }
  const f = run('factory', fixtures.factory);
  assert.equal(f.windows[0].used_percentage, 20);
  assert.equal(f.windows[0].resets_at, 1800000000);
  assert.equal(f.windows[1].used_percentage, 0);
  assert.deepEqual(f.windows.at(-1), { label: '额外用量余额', amount: 12.5, unit: 'USD', period: 'balance' });
  assert.deepEqual(run('agnes-code', fixtures['agnes-code']).windows.map(x => x.amount), [600, 500, 100]);
  assert.equal(run('catpaw', fixtures.catpaw).windows[0].amount, 73);
  assert.deepEqual(run('loomy', fixtures.loomy).windows.map(x => x.amount), [40, 8], 'daily remaining preferred over dailyBalance');
  const zeros = { factory: { limits: { standard: { fiveHour: { usedPercent: 0 } } }, extraUsageBalanceCents: 0 }, 'agnes-code': { data: { total_balance: 0 } }, catpaw: { code: 0, data: { availableCredits: 0 } }, loomy: { code: '000000', data: { dailyRemainingPoints: 0, balance: 0 } } };
  for (const [provider, body] of Object.entries(zeros)) {
    const output = run(provider, body);
    assert.equal(output.error, null);
    for (const w of output.windows) {
      if (w.period === 'balance') {
        assert.equal(w.amount, 0);
        for (const key of ['limit', 'used_percentage', 'remaining_percentage', 'resets_at']) assert(!(key in w));
      }
    }
  }
  for (const [provider, body] of Object.entries(fixtures)) {
    if (provider === 'factory') continue;
    for (const w of run(provider, body).windows) {
      assert.match(w.label, /余额/);
      assert.equal(w.period, 'balance');
      assert.equal(w.unit, 'credits');
      for (const key of ['limit', 'used_percentage', 'remaining_percentage', 'resets_at']) assert(!(key in w));
    }
  }
  for (const value of [null, '', ' ', true, {}, [], 'NaN', 'Infinity', -1]) {
    assert.equal(run('agnes-code', { data: { total_balance: value } }).error, 'parse');
    assert.equal(run('catpaw', { code: 0, data: { availableCredits: value } }).error, 'parse');
    assert.equal(run('loomy', { code: '000000', data: { balance: value } }).error, 'parse');
    assert.equal(run('factory', { limits: { standard: { fiveHour: { usedPercent: value } } } }).error, 'parse');
  }
  assert.equal(run('factory', { plan: 'Pro', limits: { standard: { fiveHour: {} } } }).error, 'parse');
  assert.equal(run('catpaw', { code: 4011, data: { balance: 10 } }).error, 'auth');
  assert.equal(run('loomy', { code: '100002', data: { balance: 10 } }).error, 'auth');
  assert.equal(run('agnes-code', { code: 'bad', data: { total_balance: 10 } }).error, 'parse');
  assert.equal(run('catpaw', fixtures.catpaw, { auth: { authMode: 'apikey' } }).error, 'no-auth');
  assert.equal(run('loomy', fixtures.loomy, { auth: { authMode: 'apikey' } }).error, 'no-auth');
  assert.equal(run('factory', fixtures.factory, { auth: { authMode: 'auth' } }).error, 'no-auth');
  assert.equal(run('agnes-code', fixtures['agnes-code'], { auth: { authMode: 'auth' } }).error, null);
  assert.equal(parseCommunityUsage('unknown', {}), null);
  assert(!existsSync(join(temp, '.claude')));
  console.log(`PASS ${scenarios} offline community provider wrapper scenarios across 4 types; no real credentials or vendor requests`);
} finally {
  assert.equal(dirname(temp), tmpdir());
  assert(basename(temp).startsWith('tokenhud-community-'));
  rmSync(temp, { recursive: true, force: true });
}
