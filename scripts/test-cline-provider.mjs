#!/usr/bin/env node
// Cline 额度 provider 离线回归: stub curl + 临时 HOME, 不触网、不读真实凭证
// 跑法: node scripts/test-cline-provider.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const PROVIDER = join(ROOT, 'Sources/TokenHUD/mjs/cline-usage-provider.mjs');

function makeHome() {
  const home = join(tmpdir(), `cline-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  mkdirSync(join(home, '.claude/hud'), { recursive: true });
  mkdirSync(join(home, 'bin'), { recursive: true });
  return home;
}

// stub curl: 记录参数, 回放 $CLINE_TEST_BODY + $CLINE_TEST_CODE
// $CLINE_TEST_FLAKE 存在时: 首次调用模拟 TLS 连接失败 (exit 35, 无应答)
function installStubCurl(home) {
  const stub = join(home, 'bin/curl');
  writeFileSync(stub, `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.CLINE_TEST_CURLLOG, args.join('\\n') + '\\n');
if (process.env.CLINE_TEST_FLAKE && !fs.existsSync(process.env.CLINE_TEST_FLAKE)) {
 fs.writeFileSync(process.env.CLINE_TEST_FLAKE, ''); process.exit(35);
}
const routes = process.env.CLINE_TEST_ROUTES ? JSON.parse(fs.readFileSync(process.env.CLINE_TEST_ROUTES, 'utf8')) : {};
const url = args[args.length - 1], reply = routes[new URL(url).pathname];
if (reply) process.stdout.write(JSON.stringify(reply.body) + '\\n' + reply.status);
else process.stdout.write(fs.readFileSync(process.env.CLINE_TEST_BODY, 'utf8') + '\\n' + process.env.CLINE_TEST_CODE);
`, { mode: 0o755 });
}

function writeAuth(home, obj) {
  writeFileSync(join(home, '.claude/hud/.cline-usage-auth.json'), JSON.stringify(obj));
}

function run(home, body, code = '200', auth = { apiKey: 'clp_test' }) {
  if (auth) writeAuth(home, auth);
  writeFileSync(join(home, 'body'), body);
  const r = spawnSync(process.execPath, [PROVIDER], {
    env: {
      ...process.env, HOME: home,
      USAGE_AUTH_FILE: join(home, '.claude/hud/.cline-usage-auth.json'),
      USAGE_CACHE_FILE: join(home, '.claude/hud/.cline-usage-cache.json'),
      TOKENHUD_CURL: join(home, 'bin/curl'),
      CLINE_TEST_CURLLOG: join(home, 'curl.log'),
      CLINE_TEST_BODY: join(home, 'body'),
      CLINE_TEST_CODE: code,
      CLINE_TEST_ROUTES: existsSync(join(home, 'routes.json')) ? join(home, 'routes.json') : '',
      CLINE_TEST_FLAKE: process.env.CLINE_TEST_FLAKE ? join(home, 'flaked') : '',
    },
    encoding: 'utf8', timeout: 30000,
  });
  assert.equal(r.status, 0, r.stderr);
  const p = join(home, '.claude/hud/.cline-usage-cache.json');
  return existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null;
}

const THREE = JSON.stringify({ data: { limits: [
  { type: 'five_hour', percentUsed: 64, resetsAt: '2026-10-29T11:37:30.228734966Z' },
  { type: 'weekly', percentUsed: 61, resetsAt: '2026-11-04T07:15:36.230979473Z' },
  { type: 'monthly', percentUsed: 83, resetsAt: '2026-11-13T06:51:16.233383826Z' },
] }, success: true });

test('三桶映射: five_hour/weekly→seven_day/monthly, 百分比原值, resets_at 秒', () => {
  const home = makeHome();
  installStubCurl(home);
  const c = run(home, THREE);
  assert.equal(c.five_hour.used_percentage, 64);
  assert.equal(c.seven_day.used_percentage, 61);
  assert.equal(c.monthly.used_percentage, 83);
  assert.equal(c.five_hour.resets_at, Math.floor(Date.parse('2026-10-29T11:37:30.228Z') / 1000));
  assert.equal(c.monthly.resets_at, Math.floor(Date.parse('2026-11-13T06:51:16.233Z') / 1000));
  assert.ok(c.monthly.resets_at > 1e9 && c.monthly.resets_at < 1e11, 'resets_at 须为秒级 epoch');
  assert.equal(c.error, null);
  assert.equal(c.stale, false);
  const log = readFileSync(join(home, 'curl.log'), 'utf8');
  assert.ok(log.includes('https://api.cline.bot/api/v1/users/me/plan/usage-limits'), '须请求 usage-limits');
  assert.ok(log.includes('Bearer clp_test'), '须带 Bearer');
  assert.ok(!log.includes('usages'), '不再翻页 usages');
});

test('未知 type 忽略; 部分桶也成功', () => {
  const home = makeHome();
  installStubCurl(home);
  const c = run(home, JSON.stringify({ data: { limits: [
    { type: 'daily', percentUsed: 99 },
    { type: 'weekly', percentUsed: 42.5, resetsAt: '2026-11-04T07:15:36.18167754Z' },
  ] }, success: true }));
  assert.equal(c.five_hour, null);
  assert.equal(c.monthly, null);
  assert.equal(c.seven_day.used_percentage, 42.5);
  assert.equal(c.error, null);
});

test('越界百分比夹到 0..100', () => {
  const home = makeHome();
  installStubCurl(home);
  const c = run(home, JSON.stringify({ data: { limits: [
    { type: 'monthly', percentUsed: 150, resetsAt: '2026-11-13T06:51:16Z' },
    { type: 'five_hour', percentUsed: -5, resetsAt: '2026-10-29T11:37:30Z' },
  ] }, success: true }));
  assert.equal(c.monthly.used_percentage, 100);
  assert.equal(c.five_hour.used_percentage, 0);
});

test('全无已知桶 → parse; 失败保旧桶 stale', () => {
  const home = makeHome();
  installStubCurl(home);
  run(home, THREE);
  let c = run(home, JSON.stringify({ data: { limits: [{ type: 'bogus', percentUsed: 50 }] }, success: true }));
  assert.equal(c.error, 'parse');
  assert.equal(c.stale, true);
  assert.equal(c.five_hour.used_percentage, 64, '失败不得清旧桶');

  c = run(home, '{}', '500');
  assert.equal(c.error, 'network');
  assert.equal(c.monthly.used_percentage, 83);
});

test('无旧数据时失败只写错误态', () => {
  const home = makeHome();
  installStubCurl(home);
  const c = run(home, '{}', '500');
  assert.equal(c.error, 'network');
  assert.equal(c.five_hour, undefined);
  assert.ok(c.detail);
});

test('凭证缺失 → no-auth 不发请求; 401 → auth', () => {
  const home = makeHome();
  installStubCurl(home);
  let c = run(home, THREE, '200', null);
  assert.equal(c.error, 'no-auth');
  assert.ok(!existsSync(join(home, 'curl.log')), 'no-auth 不发请求');

  c = run(home, '{}', '401');
  assert.equal(c.error, 'auth');
});

test('不写回凭证; auth 文件说明键保留', () => {
  const home = makeHome();
  installStubCurl(home);
  const auth = { apiKey: 'clp_test', _note: '说明文字' };
  run(home, THREE, '200', auth);
  assert.deepEqual(JSON.parse(readFileSync(join(home, '.claude/hud/.cline-usage-auth.json'), 'utf8')), auth);
});

test('连接层失败交给外层 Runner 重试; 有应答失败也不内层重试', () => {
  const home = makeHome();
  installStubCurl(home);
  process.env.CLINE_TEST_FLAKE = '1';
  const c = run(home, THREE);
  delete process.env.CLINE_TEST_FLAKE;
  assert.equal(c.error, 'network', '适配器单次尝试，由 Runner 统一重试');
  assert.equal(readFileSync(join(home, 'curl.log'), 'utf8').split('\n').filter(l => l.startsWith('https://api.cline.bot/api/v1/')).length, 1);

  const home2 = makeHome();
  installStubCurl(home2);
  run(home2, '{}', '500');
  assert.equal(readFileSync(join(home2, 'curl.log'), 'utf8').split('\n').filter(l => l.startsWith('https://api.cline.bot/api/v1/')).length, 1);
});

function creditFixture(balance, status = 200) {
  const home = makeHome(); installStubCurl(home);
  writeFileSync(join(home, 'routes.json'), JSON.stringify({
    '/api/v1/users/me': { status: 200, body: { success: true, data: { clineUserId: 'account/a', id: 'other' } } },
    '/api/v1/users/account%2Fa/balance': { status, body: { success: status === 200, data: { balance } } },
  }));
  return home;
}

test('ClinePass 404 reads an independent USD credit pool with native client headers', () => {
  const home = creditFixture('1250000');
  const cache = run(home, '{}', '404');
  assert.equal(cache.error, null); assert.equal(cache.stale, false);
  assert.deepEqual(cache.windows, [{ label: '充值余额', amount: 1.25, unit: 'USD', period: 'balance' }]);
  for (const field of ['five_hour', 'seven_day', 'monthly']) assert.equal(cache[field], null);
  const log = readFileSync(join(home, 'curl.log'), 'utf8');
  assert.deepEqual(log.split('\n').filter(line => line.startsWith('https://api.cline.bot/api/v1/')), [
    'https://api.cline.bot/api/v1/users/me/plan/usage-limits',
    'https://api.cline.bot/api/v1/users/me',
    'https://api.cline.bot/api/v1/users/account%2Fa/balance',
  ]);
  assert.ok(log.includes('--http1.1'), 'native account and balance reads require the working HTTP/1.1 transport');
  assert.ok(log.includes('X-CLIENT-TYPE: cline-desktop'));
  assert.ok(log.includes('X-CLIENT-VERSION: 3.5.54')); assert.ok(log.includes('User-Agent: Cline/3.5.54'));
  assert.ok(!log.includes('/chat/completions')); assert.ok(!JSON.stringify(cache).includes('account/a'));
});

test('zero credits are valid; missing or malformed credits remain unknown', () => {
  assert.equal(run(creditFixture(0), '{}', '404').windows[0].amount, 0);
  for (const value of [null, '', -1, true, {}, 'not-a-number']) {
    const cache = run(creditFixture(value), '{}', '404');
    assert.equal(cache.error, 'parse'); assert.equal(cache.windows, undefined);
  }
});

test('credit endpoint refusal does not become a successful empty subscription', () => {
  for (const [status, error] of [[401, 'auth'], [403, 'auth'], [429, 'ratelimit'], [500, 'network']]) {
    const cache = run(creditFixture(0, status), '{}', '404');
    assert.equal(cache.error, error); assert.equal(cache.windows, undefined);
  }
});

test('failed credit reads preserve the previous balance without inventing subscription windows', () => {
  const home = creditFixture(2500000); const good = run(home, '{}', '404');
  const stale = run(home, '{}', '500');
  assert.equal(stale.error, 'network'); assert.equal(stale.stale, true);
  assert.deepEqual(stale.windows, good.windows); assert.equal(stale.five_hour, null);
});

test('模板路由: fetch.sh 与 statusline 指向 cline-usage-provider, 三桶齐备', () => {
  const fetchSh = readFileSync(join(ROOT, 'Sources/TokenHUD/providers/cline/fetch.sh'), 'utf8');
  assert.ok(fetchSh.includes('cline-usage-provider.mjs'));
  const sl = readFileSync(join(ROOT, 'Sources/TokenHUD/mjs/statusline.mjs'), 'utf8');
  const line = sl.split('\n').find(l => l.includes('provider: CLINE_PROVIDER'));
  assert.ok(line && line.includes('provider: CLINE_PROVIDER') && line.includes("monthly: '月'"));
  const manifest = JSON.parse(readFileSync(join(ROOT, 'Sources/TokenHUD/providers/cline/manifest.json'), 'utf8'));
  assert.ok(manifest.buckets.five_hour && manifest.buckets.seven_day && manifest.buckets.monthly);
  assert.equal(manifest.queryUrl, 'https://api.cline.bot/api/v1/users/me/plan/usage-limits');
  assert.equal(manifest.refreshUrl, 'https://api.cline.bot/api/v1/chat/completions');
  assert.equal(manifest.refreshProtocol, 'openai');
});
