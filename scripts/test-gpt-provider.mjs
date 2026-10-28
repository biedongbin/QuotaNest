#!/usr/bin/env node
// GPT provider 离线回归: stub curl + 临时 HOME, 不触网、不读真实凭证
// 跑法: node scripts/test-gpt-provider.mjs  (node >= 18, 内置 test runner)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, statSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const PROVIDER = join(ROOT, 'Sources/TokenHUD/mjs/gpt-usage-provider.mjs');
const NODE = process.execPath;

// 每用例独立临时 HOME: codex auth / hud auth / cache / stub curl 全隔离
function makeHome() {
  const home = join(tmpdir(), `gpt-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  mkdirSync(join(home, '.codex'), { recursive: true });
  mkdirSync(join(home, '.claude/hud'), { recursive: true });
  mkdirSync(join(home, 'bin'), { recursive: true });
  return home;
}

// stub curl: 输出 fixture(body+http_code), 记录调用参数; fixture code 文件内容=="EXIT7" 模拟网络失败
function installStubCurl(home) {
  const stub = join(home, 'bin/curl');
  writeFileSync(stub, `#!/bin/sh
printf '%s\\n' "$@" >> "$GPT_TEST_CURLLOG"
CODE=$(cat "$GPT_TEST_FIXTURE_CODE")
if [ "$CODE" = "EXIT7" ]; then exit 7; fi
cat "$GPT_TEST_FIXTURE_BODY"
printf '\\n%s\\n' "$CODE"
`, { mode: 0o755 });
  return stub;
}

function writeCodexAuth(home, obj) {
  writeFileSync(join(home, '.codex/auth.json'), JSON.stringify(obj), { mode: 0o600 });
}

// 跑 provider; envOverrides 覆盖默认 env
function runProvider(home, { env: extra = {} } = {}) {
  const env = {
    ...process.env,
    HOME: home,
    CODEX_HOME: join(home, '.codex'),
    USAGE_AUTH_FILE: join(home, '.claude/hud/.gpt-usage-auth.json'),
    USAGE_CACHE_FILE: join(home, '.claude/hud/.gpt-usage-cache.json'),
    TOKENHUD_CURL: join(home, 'bin/curl'),
    GPT_TEST_CURLLOG: join(home, 'curl.log'),
    GPT_TEST_FIXTURE_BODY: join(home, 'fixture-body'),
    GPT_TEST_FIXTURE_CODE: join(home, 'fixture-code'),
    ...extra,
  };
  return spawnSync(NODE, [PROVIDER], { env, encoding: 'utf8', timeout: 20000 });
}

function setFixture(home, httpCode, body) {
  const bodyF = join(home, 'fixture-body'), codeF = join(home, 'fixture-code');
  writeFileSync(bodyF, body);
  writeFileSync(codeF, String(httpCode));
  return { bodyF, codeF };
}

function readCache(home) {
  const p = join(home, '.claude/hud/.gpt-usage-cache.json');
  return existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null;
}

// 官方 wham 响应样例 (字段名/形态取自 9router 解析器兼容集)
const WHAM = ({ primary, secondary, container = 'rate_limit' }) => {
  const rl = {};
  if (primary) rl.primary_window = primary;
  if (secondary) rl.secondary_window = secondary;
  return JSON.stringify(container === 'rate_limit' ? { rate_limit: rl, plan_type: 'plus' } : { [container]: rl });
};

test('双窗口正常: primary→five_hour, secondary→seven_day, 秒级 reset_at', () => {
  const home = makeHome();
  installStubCurl(home);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'AT', account_id: 'ACC1' } });
  setFixture(home, 200, WHAM({
    primary: { used_percent: 12.5, reset_at: 1791450000 },
    secondary: { used_percent: 40, reset_at: 1792000000 },
  }));
  const r = runProvider(home);
  console.error("DIAG status=",r.status,"stderr=",(r.stderr||"").slice(0,300),"cache=",(readCache(home)?JSON.stringify(readCache(home)).slice(0,200):"null"),"curllog=",(function(){try{return readFileSync(join(home,"curl.log"),"utf8")}catch(e){return "(none)"}})());
  assert.equal(r.status, 0, r.stderr);
  const c = readCache(home);
  assert.equal(c.five_hour.used_percentage, 12.5);
  assert.equal(c.five_hour.resets_at, 1791450000);
  assert.equal(c.seven_day.used_percentage, 40);
  assert.equal(c.seven_day.resets_at, 1792000000);
  assert.equal(c.error, null);
  // 请求目标: 官方 URL + account-id 头 + Bearer
  const log = readFileSync(join(home, 'curl.log'), 'utf8');
  assert.ok(log.includes('https://chatgpt.com/backend-api/wham/usage'), '须请求官方 URL');
  assert.ok(log.includes('chatgpt-account-id: ACC1'), '须带 account-id');
  assert.ok(log.includes('Authorization: Bearer AT'), '须带 Bearer');
  assert.ok(!log.includes('localhost:20128'), '不得请求 9router');
});

test('percent_used 备选字段 + rate_limits 容器 + primary/secondary 短名', () => {
  const home = makeHome();
  installStubCurl(home);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'AT', account_id: 'A' } });
  writeFileSync(join(home, 'fixture-body'), JSON.stringify({
    rate_limits: { primary: { percent_used: 7 }, secondary: { percent_used: 88 } },
  }));
  writeFileSync(join(home, 'fixture-code'), '200');
  runProvider(home);
  const c = readCache(home);
  assert.equal(c.five_hour.used_percentage, 7);
  assert.equal(c.seven_day.used_percentage, 88);
});

test('rate_limits_by_limit_id.codex 容器兼容', () => {
  const home = makeHome();
  installStubCurl(home);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'AT' } });
  writeFileSync(join(home, 'fixture-body'), JSON.stringify({
    rate_limits_by_limit_id: { codex: { primary_window: { used_percent: 5 }, secondary_window: { used_percent: 6 } } },
  }));
  writeFileSync(join(home, 'fixture-code'), '200');
  runProvider(home);
  const c = readCache(home);
  assert.equal(c.five_hour.used_percentage, 5);
  assert.equal(c.seven_day.used_percentage, 6);
});

test('reset 时间: 毫秒/ISO/相对秒 三态归一为 epoch 秒', () => {
  const home = makeHome();
  installStubCurl(home);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'AT' } });
  setFixture(home, 200, JSON.stringify({ rate_limit: {
    primary_window: { used_percent: 1, reset_at: 1791450000000 },            // 毫秒
    secondary_window: { used_percent: 2, reset_at: '2026-10-15T00:00:00Z' }, // ISO
  } }));
  runProvider(home);
  let c = readCache(home);
  assert.equal(c.five_hour.resets_at, 1791450000);
  assert.equal(c.seven_day.resets_at, Math.floor(Date.parse('2026-10-15T00:00:00Z') / 1000));

  setFixture(home, 200, JSON.stringify({ rate_limit: {
    primary_window: { used_percent: 1, reset_after_seconds: 3600 }, // 相对秒
  } }));
  const t0 = Math.floor(Date.now() / 1000);
  runProvider(home);
  c = readCache(home);
  assert.ok(c.five_hour.resets_at >= t0 + 3590 && c.five_hour.resets_at <= t0 + 3610);
});

test('仅一个窗口: 另一桶为 null, 仍算成功', () => {
  const home = makeHome();
  installStubCurl(home);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'AT' } });
  setFixture(home, 200, JSON.stringify({ rate_limit: { primary_window: { used_percent: 0 } } }));
  runProvider(home);
  const c = readCache(home);
  assert.equal(c.five_hour.used_percentage, 0);
  assert.equal(c.seven_day, null);
  assert.equal(c.error, null);
});

test('失败保旧: 先成功后 500, 旧桶保留且 stale', () => {
  const home = makeHome();
  installStubCurl(home);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'AT' } });
  setFixture(home, 200, WHAM({ primary: { used_percent: 30, reset_at: 1791450000 } }));
  runProvider(home);
  setFixture(home, 500, '{"x":1}');
  runProvider(home);
  const c = readCache(home);
  assert.equal(c.five_hour.used_percentage, 30, '失败不得清空旧桶');
  assert.equal(c.stale, true);
  assert.ok(c.error);
});

test('畸形 JSON → parse 错误保旧; 空窗口体 → 不伪造 0%', () => {
  const home = makeHome();
  installStubCurl(home);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'AT' } });
  setFixture(home, 200, WHAM({ primary: { used_percent: 55, reset_at: 1 } }));
  runProvider(home);
  setFixture(home, 200, '<html>bad</html>');
  runProvider(home);
  assert.equal(readCache(home).five_hour.used_percentage, 55);

  setFixture(home, 200, JSON.stringify({ rate_limit: { primary_window: { reset_at: 1 } } }));
  const r = runProvider(home);
  assert.equal(r.status, 0);
  // 空窗口体 = 无有效窗口 → 业务失败 → 保旧 (仍是 55), 不伪造 0%
  assert.equal(readCache(home).five_hour.used_percentage, 55, '空窗口体走保旧, 不伪造 0%');
});

test('空响应且无旧缓存: 不伪造 0%, 写 parse 错误', () => {
  const home = makeHome();
  installStubCurl(home);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'AT' } });
  setFixture(home, 200, JSON.stringify({ rate_limit: { primary_window: { reset_at: 1 } } }));
  const r = runProvider(home);
  assert.equal(r.status, 0);
  const c = readCache(home);
  assert.equal(c.five_hour ?? null, null, '无 used_percent 不伪造 0');
  assert.equal(c.error, 'parse');
});

test('401/403 → auth 错误; 429/网络失败 → network 错误, 均保旧', () => {
  const home = makeHome();
  installStubCurl(home);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'AT' } });
  setFixture(home, 200, WHAM({ primary: { used_percent: 10, reset_at: 1 } }));
  runProvider(home);

  setFixture(home, 401, '{"detail":"unauthorized"}');
  runProvider(home);
  assert.equal(readCache(home).error, 'auth');

  setFixture(home, 429, 'rate limited');
  runProvider(home);
  assert.equal(readCache(home).error, 'network');
  assert.equal(readCache(home).five_hour.used_percentage, 10);

  setFixture(home, 'EXIT7', '');
  runProvider(home);
  assert.equal(readCache(home).error, 'network');
});

test('凭证缺失/非 chatgpt 登录 → no-auth, 不发请求', () => {
  const home = makeHome();
  installStubCurl(home);
  // 完全无 codex auth
  runProvider(home);
  assert.equal(readCache(home).error, 'no-auth');
  // apikey 模式
  writeCodexAuth(home, { auth_mode: 'apikey', OPENAI_API_KEY: 'sk-x' });
  runProvider(home);
  assert.equal(readCache(home).error, 'no-auth');
  assert.ok(!existsSync(join(home, 'curl.log')), 'no-auth 不得发请求');
});

test('不改写 Codex auth: 内容与 mtime 不变', () => {
  const home = makeHome();
  installStubCurl(home);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'AT', account_id: 'A', refresh_token: 'RT' } });
  const p = join(home, '.codex/auth.json');
  const before = statSync(p);
  setFixture(home, 200, WHAM({ primary: { used_percent: 9, reset_at: 1 } }));
  runProvider(home);
  const after = statSync(p);
  assert.equal(after.mtimeMs, before.mtimeMs);
  const j = JSON.parse(readFileSync(p, 'utf8'));
  assert.equal(j.tokens.refresh_token, 'RT');
});

test('指针配置: codexAuthFile 可覆盖 Codex auth 路径; 旧 9router auth 字段被忽略', () => {
  const home = makeHome();
  installStubCurl(home);
  const alt = join(home, 'alt-auth.json');
  writeFileSync(alt, JSON.stringify({ auth_mode: 'chatgpt', tokens: { access_token: 'ALT', account_id: 'ACC2' } }));
  // 旧 9router 形态 auth: apiUrl/limitsArrayPath 等旧键 + 新指针键
  writeFileSync(join(home, '.claude/hud/.gpt-usage-auth.json'), JSON.stringify({
    apiUrl: 'http://localhost:20128/api/usage/old',
    limitsArrayPath: 'quotas.session',
    headers: { Accept: '' },
    codexAuthFile: alt,
  }));
  setFixture(home, 200, WHAM({ secondary: { used_percent: 66, reset_at: 1792000000 } }));
  runProvider(home);
  const c = readCache(home);
  assert.equal(c.seven_day.used_percentage, 66);
  const log = readFileSync(join(home, 'curl.log'), 'utf8');
  assert.ok(!log.includes('localhost:20128'), '旧 apiUrl 必须被忽略');
  assert.ok(log.includes('chatgpt-account-id: ACC2'));
});

test('账号切换: 换 account 后失败不保旧账号数据', () => {
  const home = makeHome();
  installStubCurl(home);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'AT', account_id: 'OLD' } });
  setFixture(home, 200, WHAM({ primary: { used_percent: 77, reset_at: 1 } }));
  runProvider(home);
  // 换账号后 401: 旧账号 77% 不得保留
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'AT2', account_id: 'NEW' } });
  setFixture(home, 401, '{}');
  runProvider(home);
  const c = readCache(home);
  assert.notEqual(c.five_hour?.used_percentage, 77);
});

// 模板/路由一致性: fetch.sh 指向专用脚本, statusline 路由专用 provider
test('模板 fetch.sh 与 statusline 均路由到 gpt-usage-provider', () => {
  const fetchSh = readFileSync(join(ROOT, 'Sources/TokenHUD/providers/gpt/fetch.sh'), 'utf8');
  assert.ok(fetchSh.includes('gpt-usage-provider.mjs'), 'fetch.sh 须调专用脚本');
  assert.ok(!fetchSh.includes('glm-usage-provider.mjs'), '不得再走 glm 泛用脚本');
  const sl = readFileSync(join(ROOT, 'Sources/TokenHUD/mjs/statusline.mjs'), 'utf8');
  assert.ok(/GPT_PROVIDER\s*=\s*join\(HUD_DIR, ['"]gpt-usage-provider\.mjs/.test(sl));
  const gptLine = sl.split('\n').find(l => l.includes("'GPT':"));
  assert.ok(gptLine.includes('provider: GPT_PROVIDER'), 'GPT 须指定专用 provider');
  assert.ok(gptLine.includes("five_hour: '5h'"), 'GPT 须声明 5h 桶');
  const manifest = JSON.parse(readFileSync(join(ROOT, 'Sources/TokenHUD/providers/gpt/manifest.json'), 'utf8'));
  assert.equal(manifest.queryUrl, 'https://chatgpt.com/backend-api/wham/usage');
  assert.ok(manifest.buckets.five_hour);
});

// 临时 HOME 留在系统临时目录, 由 OS 清理兜底, 不做跨用例强删
