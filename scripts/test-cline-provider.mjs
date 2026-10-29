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
  writeFileSync(stub, `#!/bin/sh
printf '%s\\n' "$@" >> "$CLINE_TEST_CURLLOG"
if [ -n "$CLINE_TEST_FLAKE" ] && [ ! -f "$CLINE_TEST_FLAKE" ]; then
  : > "$CLINE_TEST_FLAKE"
  echo 'curl: (35) SSL_connect failed' >&2
  exit 35
fi
cat "$CLINE_TEST_BODY"
printf '\\n%s\\n' "$CLINE_TEST_CODE"
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

test('连接层失败重试一次即成功; 有应答失败不重试', () => {
  const home = makeHome();
  installStubCurl(home);
  process.env.CLINE_TEST_FLAKE = '1';
  const c = run(home, THREE);
  delete process.env.CLINE_TEST_FLAKE;
  assert.equal(c.error, null, '首次 TLS 失败须重试成功');
  assert.equal(c.five_hour.used_percentage, 64);
  assert.equal(readFileSync(join(home, 'curl.log'), 'utf8').split('\n').filter(l => l.includes('https://')).length, 2);

  const home2 = makeHome();
  installStubCurl(home2);
  run(home2, '{}', '500');
  assert.equal(readFileSync(join(home2, 'curl.log'), 'utf8').split('\n').filter(l => l.includes('https://')).length, 1);
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
