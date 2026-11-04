#!/usr/bin/env node
// Offline only: exercise each shipped fetch.sh with an isolated HOME and fake curl.
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, rmSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { balanceProviders, parseBalance } from '../Sources/TokenHUD/mjs/catalog-balance-provider.mjs';
import { normalizeUsage } from '../Sources/TokenHUD/mjs/usage-normalize.mjs';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const temp = mkdtempSync(join(tmpdir(), 'tokenhud-catalog-balances-'));
const hud = join(temp, 'hud');
mkdirSync(hud);
const snapshotFile = join(temp, 'snapshot.json');
const originalFile = join(temp, 'original-auth.json');
const cacheFile = join(temp, 'cache.json');
const argsFile = join(temp, 'curl-args.json');
const curl = join(temp, 'fake-curl');
const adapter = join(repo, 'Sources/TokenHUD/mjs/catalog-balance-provider.mjs');
copyFileSync(adapter, join(hud, 'catalog-balance-provider.mjs'));
writeFileSync(curl, `#!${process.execPath}\nimport {writeFileSync} from 'node:fs';\nwriteFileSync(process.env.FIXTURE_ARGS, JSON.stringify(process.argv.slice(2)));\nprocess.stdout.write(process.env.FIXTURE_BODY + '\\n' + process.env.FIXTURE_STATUS);\nprocess.exit(Number(process.env.FIXTURE_EXIT || 0));\n`, { mode: 0o700 });
const original = JSON.stringify({ apiKey: 'keyB', refreshApiKey: 'keyB', cookieAuth: 'session=old-cookie', cookieToken: 'old-cookie', scheduleTimes: ['10:00'] });
writeFileSync(originalFile, original);
const snapshot = { queryKey: 'keyA', apiKey: 'keyB', refreshApiKey: 'keyB', cookieAuth: 'session=old-cookie', cookieToken: 'old-cookie', headers: { Authorization: 'Bearer keyB' }, authFile: originalFile, queryUrl: 'https://attacker.invalid/query' };
let count = 0;
const args = () => JSON.parse(readFileSync(argsFile, 'utf8'));
function run(provider, body, { auth = snapshot, status = 200, exit = 0, stdoutOnly = true } = {}) {
  const authText = JSON.stringify(auth);
  writeFileSync(snapshotFile, authText);
  const cache = JSON.stringify({ generatedAt: 123, windows: [{ label: '上次余额', amount: 8, unit: 'USD', period: 'balance' }] });
  writeFileSync(cacheFile, cache);
  const wrapper = join(temp, 'fetch.sh');
  writeFileSync(wrapper, readFileSync(join(repo, `Sources/TokenHUD/providers/${provider}/fetch.sh`), 'utf8').replaceAll('{SLUG}', 'fixture-account'));
  const result = spawnSync('/bin/zsh', [wrapper], {
    encoding: 'utf8', timeout: 5000,
    env: { PATH: process.env.PATH, HOME: temp, TOKENHUD_NODE: process.execPath, TOKENHUD_HUD_DIR: hud,
      TOKENHUD_AUTH_FILE: snapshotFile, TOKENHUD_CACHE_FILE: cacheFile, TOKENHUD_STDOUT_ONLY: stdoutOnly ? '1' : '0',
      TOKENHUD_CURL: curl, TOKENHUD_QUERY_URL: 'https://attacker.invalid/env', FIXTURE_ARGS: argsFile,
      FIXTURE_BODY: typeof body === 'string' ? body : JSON.stringify(body), FIXTURE_STATUS: String(status), FIXTURE_EXIT: String(exit) },
  });
  assert.equal(result.status, 0, `${provider}: ${result.stderr}`);
  assert.equal(readFileSync(snapshotFile, 'utf8'), authText, 'snapshot must remain unchanged');
  assert.equal(readFileSync(originalFile, 'utf8'), original, 'persistent credentials must remain unchanged');
  if (stdoutOnly) assert.equal(readFileSync(cacheFile, 'utf8'), cache, 'stdout-only must not write cache');
  const output = JSON.parse(result.stdout);
  if (!stdoutOnly) assert.deepEqual(JSON.parse(readFileSync(cacheFile, 'utf8')), output);
  count++;
  return output;
}
const fixtures = {
  deepseek: { is_available: true, balance_infos: [{ currency: 'CNY', total_balance: '110.00', granted_balance: '10.00', topped_up_balance: '100.00' }, { currency: 'USD', total_balance: '2.5' }] },
  'moonshot-cn': { code: 0, status: true, data: { available_balance: 49.58 } },
  moonshot: { code: 0, status: true, data: { available_balance: '12.5' } },
  openrouter: { data: { total_credits: 20, total_usage: 3.5 } },
  aihubmix: { object: 'list', total_usage: 12.5 },
  'stepfun-cn': { object: 'account', type: 'prepaid', balance: 26, total_cash_balance: 100, total_voucher_balance: 200 },
  stepfun: { object: 'account', balance: '14.2', total_cash_balance: 200 },
  'vercel-ai-gateway': { balance: '95.50', total_used: '4.50' },
};
const expected = { deepseek: [110, 2.5], 'moonshot-cn': [49.58], moonshot: [12.5], openrouter: [16.5], aihubmix: [12.5], 'stepfun-cn': [26], stepfun: [14.2], 'vercel-ai-gateway': [95.5] };
try {
  for (const [provider, body] of Object.entries(fixtures)) {
    const manifest = JSON.parse(readFileSync(join(repo, `Sources/TokenHUD/providers/${provider}/manifest.json`), 'utf8'));
    assert.equal(manifest.autoCreateDefault, false);
    assert.equal(manifest.authMode, 'apikey');
    assert.deepEqual(manifest.quotaAuthModes, ['apikey']);
    assert.equal(manifest.queryAuth, 'bearer');
    assert.equal(manifest.quotaMode, 'script');
    assert.equal(manifest.inheritQueryUrl, balanceProviders[provider].url);
    assert.equal(manifest.testModel, '');
    const result = run(provider, body);
    assert.equal(result.error, null);
    assert.equal(result.stale, false);
    assert.deepEqual(result.windows.map(window => window.amount), expected[provider]);
    assert.equal(normalizeUsage(result).windows.length, result.windows.length);
    for (const window of result.windows) {
      assert.equal(window.unit, provider === 'deepseek' ? (window.amount === 110 ? 'CNY' : 'USD') : balanceProviders[provider].unit);
      assert.equal(window.period, 'balance');
      assert.equal(window.label, '余额');
      for (const field of ['limit', 'used_percentage', 'remaining_percentage', 'resets_at']) assert(!(field in window), field);
    }
    const request = args();
    assert.equal(request[0], '-q', 'disable curlrc before any other curl argument');
    assert.equal(request.at(-1), balanceProviders[provider].url);
    assert(request.includes('Authorization: Bearer keyA'));
    assert(!JSON.stringify(request).includes('keyB'));
    assert(!JSON.stringify(request).includes('old-cookie'));
    assert(!request.includes('-L') && !request.includes('--location'));
    assert.equal(request[request.indexOf('--proto') + 1], '=https');
    assert(request.includes('--max-time') && request.includes('--connect-timeout'));
    assert.equal(run(provider, {}).error, 'parse', `${provider} missing balance`);
    assert.equal(run(provider, body, { status: 401 }).error, 'auth');
    assert.equal(run(provider, body, { status: 429 }).error, 'ratelimit');
    assert.equal(run(provider, body, { exit: 28 }).error, 'network');
    assert.equal(run(provider, '{broken').error, 'parse');
    const marker = readFileSync(argsFile, 'utf8');
    assert.equal(run(provider, body, { auth: { ...snapshot, queryKey: '' } }).error, 'no-auth');
    assert.equal(readFileSync(argsFile, 'utf8'), marker, 'must not fall back to old credentials');
  }
  const zeroBodies = {
    deepseek: { balance_infos: [{ currency: 'CNY', total_balance: '0' }] },
    moonshot: { data: { available_balance: 0 } }, 'moonshot-cn': { data: { available_balance: '0' } },
    openrouter: { data: { total_credits: 4, total_usage: 4 } }, aihubmix: { total_usage: 0 },
    stepfun: { balance: 0 }, 'stepfun-cn': { balance: '0' }, 'vercel-ai-gateway': { balance: '0', total_used: '0' },
  };
  for (const [provider, body] of Object.entries(zeroBodies)) assert.equal(run(provider, body).windows[0].amount, 0);
  for (const provider of ['stepfun', 'stepfun-cn', 'vercel-ai-gateway']) assert.equal(run(provider, { balance: '-2.5' }).windows[0].amount, -2.5);
  assert.equal(run('openrouter', { data: { total_credits: 1, total_usage: 3 } }).windows[0].amount, -2);
  assert.equal(run('openrouter', { data: { total_credits: 10 } }).error, 'parse');
  assert.equal(run('aihubmix', { total_usage: -1 }).error, 'no-query');
  assert.match(run('aihubmix', { total_usage: -1 }).message, /无限额/);
  for (const value of [null, '', '  ', true, 'NaN', 'Infinity', {}, []]) {
    assert.equal(run('vercel-ai-gateway', { balance: value }).error, 'parse');
  }
  for (const status of [403, 301, 302, 307, 308]) assert.equal(run('deepseek', fixtures.deepseek, { status }).error, 'auth');
  assert.equal(run('deepseek', fixtures.deepseek, { status: 500 }).error, 'network');
  assert.equal(run('deepseek', fixtures.deepseek, { auth: { queryKey: 'keyA\nInjected: value' } }).error, 'no-auth');
  assert.equal(run('deepseek', { balance_infos: [{ total_balance: 3 }] }).error, 'parse');
  assert.equal(parseBalance('unknown', {}), null);
  assert.equal(parseBalance('vercel-ai-gateway', []), null);
  assert.equal(run('moonshot', { code: 1, data: { available_balance: 8 } }).error, 'parse');
  assert.equal(run('vercel-ai-gateway', fixtures['vercel-ai-gateway'], { stdoutOnly: false }).windows[0].amount, 95.5);
  assert(!existsSync(join(temp, '.claude')), 'must not create or read default global auth context');
  console.log(`PASS ${count} offline catalog balance adapter scenarios across 8 provider types; no real network or credentials`);
} finally {
  assert.equal(dirname(temp), tmpdir());
  assert(basename(temp).startsWith('tokenhud-catalog-balances-'));
  rmSync(temp, { recursive: true, force: true });
}
