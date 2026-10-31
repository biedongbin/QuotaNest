#!/usr/bin/env node
// GPT provider 离线回归：假 curl + 临时 HOME/CLAUDE_CONFIG_DIR，不触网、不读真实凭证
// 跑法：node scripts/test-gpt-provider.mjs（node >= 18，内置 test runner）
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, statSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const PROVIDER = join(ROOT, 'Sources/TokenHUD/mjs/gpt-usage-provider.mjs');
const NODE = process.execPath;
const homes = [];

// 每用例独立临时 HOME：Codex auth、HUD auth/cache、假 curl 全隔离。
function makeHome() {
  const home = mkdtempSync(join(tmpdir(), 'gpt-test-'));
  homes.push(home);
  mkdirSync(join(home, '.codex'), { recursive: true });
  mkdirSync(join(home, '.claude/hud'), { recursive: true });
  mkdirSync(join(home, 'bin'), { recursive: true });
  return home;
}

after(() => {
  for (const home of homes) rmSync(home, { recursive: true, force: true });
});

// 假 curl 只输出本地 fixture，并把假认证参数记录到临时目录。
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

function authenticatedHome(accountId = 'TEST_ACCOUNT') {
  const home = makeHome();
  installStubCurl(home);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'TEST_ACCESS', account_id: accountId } });
  return home;
}

function runProvider(home, { env: extra = {} } = {}) {
  const env = {
    ...process.env,
    HOME: home,
    CLAUDE_CONFIG_DIR: join(home, '.claude'),
    CODEX_HOME: join(home, '.codex'),
    USAGE_AUTH_FILE: join(home, '.claude/hud/.gpt-usage-auth.json'),
    USAGE_CACHE_FILE: join(home, '.claude/hud/.gpt-usage-cache.json'),
    USAGE_VERBOSE: '',
    TOKENHUD_CURL: join(home, 'bin/curl'),
    GPT_TEST_CURLLOG: join(home, 'curl.log'),
    GPT_TEST_FIXTURE_BODY: join(home, 'fixture-body'),
    GPT_TEST_FIXTURE_CODE: join(home, 'fixture-code'),
    ...extra,
  };
  const result = spawnSync(NODE, [PROVIDER], { env, encoding: 'utf8', timeout: 20000 });
  assert.equal(result.status, 0, result.stderr || result.error?.message);
  return result;
}

function setFixture(home, httpCode, body) {
  writeFileSync(join(home, 'fixture-body'), body);
  writeFileSync(join(home, 'fixture-code'), String(httpCode));
}

function readCache(home) {
  const path = join(home, '.claude/hud/.gpt-usage-cache.json');
  return existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : null;
}

const WHAM = ({ primary, secondary, container = 'rate_limit', plan = 'plus' }) => {
  const limits = {};
  if (primary !== undefined) limits.primary_window = primary;
  if (secondary !== undefined) limits.secondary_window = secondary;
  return JSON.stringify({ [container]: limits, plan_type: plan });
};

function assertKnownWindows(cache, percentages) {
  assert.deepEqual(cache.windows.map(w => w.used_percentage), percentages);
  assert.ok(cache.windows.every(w => typeof w.label === 'string' && w.label.length > 0));
}

test('实测周窗口：primary 为 604800 秒且 secondary 为 null，不冒充 5h', () => {
  const home = authenticatedHome();
  setFixture(home, 200, WHAM({
    plan: 'prolite',
    primary: { used_percent: 18, limit_window_seconds: 604800, reset_at: 1793776498, reset_after_seconds: 426097 },
    secondary: null,
  }));
  runProvider(home);
  const cache = readCache(home);
  assert.equal(cache.five_hour, null);
  assert.deepEqual(cache.seven_day, { used_percentage: 18, resets_at: 1793776498 });
  assert.deepEqual(cache.windows, [{ label: '本周', period: '7天', used_percentage: 18, resets_at: 1793776498 }]);
  assert.equal(cache.monthly, null);
  assert.equal(cache.error, null);
});

test('明确时长的标准双窗口：5h 与周桶、动态周期和官方请求一致', () => {
  const home = authenticatedHome();
  setFixture(home, 200, WHAM({
    primary: { used_percent: 12.5, limit_window_seconds: 18000, reset_at: 1791450000 },
    secondary: { used_percent: 40, limit_window_seconds: 604800, reset_at: 1792000000 },
  }));
  runProvider(home);
  const cache = readCache(home);
  assert.deepEqual(cache.five_hour, { used_percentage: 12.5, resets_at: 1791450000 });
  assert.deepEqual(cache.seven_day, { used_percentage: 40, resets_at: 1792000000 });
  assert.deepEqual(cache.windows.map(w => [w.label, w.period]), [['5小时', '5小时'], ['本周', '7天']]);
  assertKnownWindows(cache, [12.5, 40]);
  assert.equal(cache.error, null);
  const log = readFileSync(join(home, 'curl.log'), 'utf8');
  assert.ok(log.includes('https://chatgpt.com/backend-api/wham/usage'), '须请求官方 URL');
  assert.ok(log.includes('chatgpt-account-id: TEST_ACCOUNT'), '须带假 account-id');
  assert.ok(log.includes('Authorization: Bearer TEST_ACCESS'), '须带假 Bearer');
  assert.ok(log.includes('--connect-timeout\n8\n'), '保留连接超时');
  assert.ok(log.includes('--max-time\n12\n'), '保留请求总超时');
  assert.ok(!log.includes('localhost:20128'), '不得请求 9router');
});

test('主次窗口位置互换后仍以时长投影，不以套餐名决定窗口个数', () => {
  const home = authenticatedHome();
  setFixture(home, 200, WHAM({
    plan: 'pro',
    primary: { used_percent: 70, limit_window_seconds: 604800, reset_at: 1792000000 },
    secondary: { used_percent: 9, limit_window_seconds: 18000, reset_at: 1791450000 },
  }));
  runProvider(home);
  const cache = readCache(home);
  assert.equal(cache.five_hour.used_percentage, 9);
  assert.equal(cache.seven_day.used_percentage, 70);
  assert.deepEqual(cache.windows.map(w => [w.label, w.period]), [['本周', '7天'], ['5小时', '5小时']]);
  assertKnownWindows(cache, [70, 9]);
});

test('percent_used、rate_limits 容器和 primary/secondary 短名兼容明确时长', () => {
  const home = authenticatedHome();
  setFixture(home, 200, JSON.stringify({ rate_limits: {
    primary: { percent_used: 7, limit_window_seconds: 18000 },
    secondary: { percent_used: 88, limit_window_seconds: 604800 },
  } }));
  runProvider(home);
  const cache = readCache(home);
  assert.equal(cache.five_hour.used_percentage, 7);
  assert.equal(cache.seven_day.used_percentage, 88);
  assertKnownWindows(cache, [7, 88]);
});

test('rate_limits_by_limit_id.codex 容器兼容，并区分其他模型限额', () => {
  const home = authenticatedHome();
  setFixture(home, 200, JSON.stringify({ rate_limits_by_limit_id: {
    codex: {
      primary_window: { used_percent: 5, limit_window_seconds: 18000 },
      secondary_window: { used_percent: 6, limit_window_seconds: 604800 },
    },
    codex_spark: { primary_window: { used_percent: 61, limit_window_seconds: 604800 } },
  } }));
  runProvider(home);
  const cache = readCache(home);
  assert.equal(cache.five_hour.used_percentage, 5);
  assert.equal(cache.seven_day.used_percentage, 6, '附加模型不得覆盖主额度');
  assertKnownWindows(cache, [5, 6, 61]);
  assert.equal(cache.windows[2].label, 'codex_spark · 本周');
});

test('附加模型的同周期窗口分别保留，容器别名不重复输出', () => {
  const home = authenticatedHome();
  const main = { primary_window: { used_percent: 18, limit_window_seconds: 604800, reset_at: 1793776498 } };
  const spark = { primary_window: { used_percent: 42, limit_window_seconds: 604800, reset_at: 1794000000 } };
  setFixture(home, 200, JSON.stringify({
    rate_limit: main,
    rate_limits: main,
    additional_rate_limits: [{ limit_name: 'Codex Spark', metered_feature: 'codex_spark', rate_limit: spark }],
    rate_limits_by_limit_id: { codex: main, codex_spark: spark },
  }));
  runProvider(home);
  const cache = readCache(home);
  assert.equal(cache.five_hour, null);
  assert.equal(cache.seven_day.used_percentage, 18);
  assertKnownWindows(cache, [18, 42]);
  assert.deepEqual(cache.windows.map(w => w.label), ['本周', 'Codex Spark · 本周']);
  assert.deepEqual(cache.windows.map(w => w.resets_at), [1793776498, 1794000000]);
});

test('同名的不同模型限制分别标注身份，相同百分比也不合并', () => {
  const home = authenticatedHome();
  const weekly = { primary_window: { used_percent: 33, limit_window_seconds: 604800 } };
  setFixture(home, 200, JSON.stringify({
    rate_limit: { primary_window: { used_percent: 18, limit_window_seconds: 604800 } },
    additional_rate_limits: [
      null,
      { limit_name: '模型额度', metered_feature: 'model_a', rate_limit: weekly },
      { limit_name: '模型额度', metered_feature: 'model_b', rate_limit: weekly },
      { limit_name: '无窗口', metered_feature: 'empty', rate_limit: null },
    ],
  }));
  runProvider(home);
  const cache = readCache(home);
  assertKnownWindows(cache, [18, 33, 33]);
  assert.deepEqual(cache.windows.map(w => w.label), ['本周', '模型额度 (model_a) · 本周', '模型额度 (model_b) · 本周']);
  assert.equal(cache.seven_day.used_percentage, 18);
});

test('空的附加对象不阻断同 identity 的有效 limit_id 窗口', () => {
  const home = authenticatedHome();
  setFixture(home, 200, JSON.stringify({
    additional_rate_limits: [{ metered_feature: 'model_a', rate_limit: {} }],
    rate_limits_by_limit_id: { model_a: { primary_window: { used_percent: 29, limit_window_seconds: 604800 } } },
  }));
  runProvider(home);
  const cache = readCache(home);
  assertKnownWindows(cache, [29]);
  assert.equal(cache.windows[0].label, 'model_a · 本周');
  assert.equal(cache.seven_day, null);
});

test('空主容器不遮住兼容容器中的有效窗口', () => {
  const home = authenticatedHome();
  setFixture(home, 200, JSON.stringify({
    rate_limit: {},
    rate_limits: { primary_window: { used_percent: 16, limit_window_seconds: 604800 } },
  }));
  runProvider(home);
  const cache = readCache(home);
  assertKnownWindows(cache, [16]);
  assert.equal(cache.seven_day.used_percentage, 16);
  assert.equal(cache.five_hour, null);
});

test('同一额度的两个同周期限制保留角色，不挤进一个 legacy 桶', () => {
  const home = authenticatedHome();
  setFixture(home, 200, WHAM({
    primary: { used_percent: 18, limit_window_seconds: 604800, reset_at: 1793776498 },
    secondary: { used_percent: 37, limit_window_seconds: 604800, reset_at: 1794000000 },
  }));
  runProvider(home);
  const cache = readCache(home);
  assert.equal(cache.five_hour, null);
  assert.equal(cache.seven_day, null, '同周期多个有效约束不可任取一个冒充唯一周额度');
  assertKnownWindows(cache, [18, 37]);
  assert.deepEqual(cache.windows.map(w => w.label), ['主额度窗口 · 本周', '次额度窗口 · 本周']);
});

test('primary_window 和 primary 别名只输出一个窗口', () => {
  const home = authenticatedHome();
  const window = { used_percent: 7, limit_window_seconds: 18000 };
  setFixture(home, 200, JSON.stringify({ rate_limit: { primary_window: window, primary: window } }));
  runProvider(home);
  assertKnownWindows(readCache(home), [7]);
});

test('未知的明确周期可读展示为 24 小时，不投影成 5h 或周', () => {
  const home = authenticatedHome();
  setFixture(home, 200, WHAM({ primary: { used_percent: 25, limit_window_seconds: 86400, reset_after_seconds: 120 } }));
  runProvider(home);
  const cache = readCache(home);
  assert.equal(cache.five_hour, null);
  assert.equal(cache.seven_day, null);
  assert.equal(cache.monthly, null);
  assertKnownWindows(cache, [25]);
  assert.equal(cache.windows[0].label, '24小时');
  assert.equal(cache.windows[0].period, '24小时');
});

test('缺失或非法时长使用中性角色和周期未知，不从重置倒计时反推', () => {
  for (const duration of [undefined, null, '', 'NaN', 0, -1]) {
    const home = authenticatedHome();
    setFixture(home, 200, WHAM({
      primary: { used_percent: 8, limit_window_seconds: duration, reset_after_seconds: 604800 },
      secondary: { used_percent: 12, reset_after_seconds: 18000 },
    }));
    runProvider(home);
    const cache = readCache(home);
    assert.equal(cache.five_hour, null);
    assert.equal(cache.seven_day, null);
    assertKnownWindows(cache, [8, 12]);
    assert.deepEqual(cache.windows.map(w => [w.label, w.period]), [['主额度窗口', '周期未知'], ['次额度窗口', '周期未知']]);
  }
});

test('reset 秒、毫秒、ISO 和相对秒归一，独立于窗口时长', () => {
  const home = authenticatedHome();
  setFixture(home, 200, WHAM({
    primary: { used_percent: 1, limit_window_seconds: 18000, reset_at: 1791450000000 },
    secondary: { used_percent: 2, limit_window_seconds: 604800, reset_at: '2026-10-15T00:00:00Z' },
  }));
  runProvider(home);
  let cache = readCache(home);
  assert.equal(cache.five_hour.resets_at, 1791450000);
  assert.equal(cache.seven_day.resets_at, Math.floor(Date.parse('2026-10-15T00:00:00Z') / 1000));
  setFixture(home, 200, WHAM({ primary: { used_percent: 1, limit_window_seconds: 604800, reset_after_seconds: 3600 } }));
  const before = Math.floor(Date.now() / 1000);
  runProvider(home);
  cache = readCache(home);
  assert.equal(cache.five_hour, null);
  assert.ok(cache.seven_day.resets_at >= before + 3590 && cache.seven_day.resets_at <= before + 3610);
});

test('真实 0% 单窗口保留，null/缺失次窗口不输出空卡', () => {
  for (const secondary of [null, undefined]) {
    const home = authenticatedHome();
    setFixture(home, 200, WHAM({ primary: { used_percent: 0, limit_window_seconds: 18000 }, secondary }));
    runProvider(home);
    const cache = readCache(home);
    assert.equal(cache.five_hour.used_percentage, 0);
    assert.equal(cache.seven_day, null);
    assertKnownWindows(cache, [0]);
    assert.equal(cache.error, null);
  }
});

test('used 缺失、null、空串、NaN 或布尔值不变成 0%，有效次窗口仍保留', () => {
  for (const used of [undefined, null, '', ' ', 'NaN', true, false]) {
    const home = authenticatedHome();
    setFixture(home, 200, WHAM({
      primary: { used_percent: used, limit_window_seconds: 18000 },
      secondary: { percent_used: '0', limit_window_seconds: 604800 },
    }));
    runProvider(home);
    const cache = readCache(home);
    assert.equal(cache.five_hour, null);
    assert.equal(cache.seven_day.used_percentage, 0);
    assertKnownWindows(cache, [0]);
    assert.equal(cache.windows[0].label, '本周');
  }
});

test('同账号失败保旧：旧 legacy 快照不因缺少时长被清掉或重分类', () => {
  const home = authenticatedHome();
  const old = {
    account_id: 'TEST_ACCOUNT',
    five_hour: { used_percentage: 30, resets_at: 1791450000 },
    seven_day: null,
    windows: [{ label: '5小时', used_percentage: 30, resets_at: 1791450000 }],
    generatedAt: 1000,
    error: null,
    stale: false,
  };
  writeFileSync(join(home, '.claude/hud/.gpt-usage-cache.json'), JSON.stringify(old));
  setFixture(home, 500, '{"x":1}');
  runProvider(home);
  const cache = readCache(home);
  assert.deepEqual(cache.five_hour, old.five_hour);
  assert.deepEqual(cache.windows, old.windows);
  assert.equal(cache.generatedAt, 1000);
  assert.equal(cache.stale, true);
  assert.equal(cache.error, 'network');
  assert.ok(cache.lastAttemptAt > 1000);
});

test('成功周响应替换历史错误 5h 投影，不保留过期桶', () => {
  const home = authenticatedHome();
  writeFileSync(join(home, '.claude/hud/.gpt-usage-cache.json'), JSON.stringify({
    account_id: 'TEST_ACCOUNT', five_hour: { used_percentage: 17, resets_at: 1793776498 },
    windows: [{ label: '5小时', used_percentage: 17, resets_at: 1793776498 }], generatedAt: 1000,
  }));
  setFixture(home, 200, WHAM({ primary: { used_percent: 18, limit_window_seconds: 604800, reset_at: 1793776498 } }));
  runProvider(home);
  const cache = readCache(home);
  assert.equal(cache.five_hour, null);
  assert.equal(cache.seven_day.used_percentage, 18);
  assert.equal(cache.windows[0].label, '本周');
  assert.ok(cache.generatedAt > 1000);
});

test('仅动态窗口也在同账号失败时保留，成功时间不前移', () => {
  const home = authenticatedHome();
  setFixture(home, 200, WHAM({ primary: { used_percent: 30, limit_window_seconds: 86400, reset_at: 1791450000 } }));
  runProvider(home);
  const previous = readCache(home);
  setFixture(home, 500, '{}');
  runProvider(home);
  const cache = readCache(home);
  assert.equal(cache.generatedAt, previous.generatedAt);
  assert.deepEqual(cache.windows, previous.windows);
  assert.equal(cache.windows[0].label, '24小时');
  assert.equal(cache.error, 'network');
  assert.equal(cache.stale, true);
});

test('畸形 JSON 或无有效 used 走 parse 并保旧，不伪造 0%', () => {
  const home = authenticatedHome();
  setFixture(home, 200, WHAM({ primary: { used_percent: 55, limit_window_seconds: 18000, reset_at: 1 } }));
  runProvider(home);
  const previous = readCache(home);
  for (const body of ['<html>bad</html>', JSON.stringify({ rate_limit: { primary_window: { reset_at: 1 } } })]) {
    setFixture(home, 200, body);
    runProvider(home);
    const cache = readCache(home);
    assert.equal(cache.five_hour.used_percentage, 55);
    assert.equal(cache.generatedAt, previous.generatedAt);
    assert.equal(cache.error, 'parse');
    assert.equal(cache.stale, true);
  }
});

test('无旧缓存且窗口为空：parse 错误而不是 0%', () => {
  const home = authenticatedHome();
  setFixture(home, 200, JSON.stringify({ rate_limit: { primary_window: { reset_at: 1 } } }));
  runProvider(home);
  const cache = readCache(home);
  assert.equal(cache.five_hour ?? null, null);
  assert.equal(cache.windows ?? null, null);
  assert.equal(cache.generatedAt ?? null, null);
  assert.equal(cache.error, 'parse');
});

test('401/403 为 auth，429 为 ratelimit，网络失败为 network，均保旧', () => {
  const home = authenticatedHome();
  setFixture(home, 200, WHAM({ primary: { used_percent: 10, limit_window_seconds: 18000, reset_at: 1 } }));
  runProvider(home);
  const previous = readCache(home);
  for (const [status, body, error] of [[401, '{}', 'auth'], [403, '{}', 'auth'], [429, 'rate limited', 'ratelimit'], ['EXIT7', '', 'network']]) {
    setFixture(home, status, body);
    runProvider(home);
    const cache = readCache(home);
    assert.equal(cache.error, error);
    assert.equal(cache.five_hour.used_percentage, 10);
    assert.deepEqual(cache.windows, previous.windows);
    assert.equal(cache.generatedAt, previous.generatedAt);
    assert.equal(cache.stale, true);
  }
});

test('凭证缺失或非 chatgpt 登录为 no-auth，不发请求', () => {
  const home = makeHome();
  installStubCurl(home);
  runProvider(home);
  assert.equal(readCache(home).error, 'no-auth');
  writeCodexAuth(home, { auth_mode: 'apikey', OPENAI_API_KEY: 'TEST_API_KEY' });
  runProvider(home);
  assert.equal(readCache(home).error, 'no-auth');
  assert.ok(!existsSync(join(home, 'curl.log')), 'no-auth 不得发请求');
});

test('Codex auth 内容与 mtime 不变，不刷新凭证', () => {
  const home = authenticatedHome();
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'TEST_ACCESS', account_id: 'TEST_ACCOUNT', refresh_token: 'TEST_REFRESH' } });
  const path = join(home, '.codex/auth.json');
  const before = statSync(path);
  const content = readFileSync(path, 'utf8');
  setFixture(home, 200, WHAM({ primary: { used_percent: 9, limit_window_seconds: 18000, reset_at: 1 } }));
  runProvider(home);
  assert.equal(statSync(path).mtimeMs, before.mtimeMs);
  assert.equal(readFileSync(path, 'utf8'), content);
});

test('绝对 codexAuthFile 指针可覆盖路径，旧 9router auth 字段被忽略', () => {
  const home = makeHome();
  installStubCurl(home);
  const alternate = join(home, 'alternate-auth.json');
  writeFileSync(alternate, JSON.stringify({ auth_mode: 'chatgpt', tokens: { access_token: 'TEST_ALT_ACCESS', account_id: 'TEST_ALT_ACCOUNT' } }));
  writeFileSync(join(home, '.claude/hud/.gpt-usage-auth.json'), JSON.stringify({
    apiUrl: 'http://localhost:20128/api/usage/old', limitsArrayPath: 'quotas.session', headers: { Accept: '' }, codexAuthFile: alternate,
  }));
  setFixture(home, 200, WHAM({ secondary: { used_percent: 66, limit_window_seconds: 604800, reset_at: 1792000000 } }));
  runProvider(home);
  const cache = readCache(home);
  assert.equal(cache.seven_day.used_percentage, 66);
  assert.equal(cache.five_hour, null);
  const log = readFileSync(join(home, 'curl.log'), 'utf8');
  assert.ok(!log.includes('localhost:20128'), '旧 apiUrl 必须被忽略');
  assert.ok(log.includes('chatgpt-account-id: TEST_ALT_ACCOUNT'));
});

test('切账号后失败不保留上一账号的 legacy 或动态窗口', () => {
  const home = authenticatedHome('TEST_OLD');
  setFixture(home, 200, WHAM({ primary: { used_percent: 77, limit_window_seconds: 86400, reset_at: 1 } }));
  runProvider(home);
  assertKnownWindows(readCache(home), [77]);
  writeCodexAuth(home, { auth_mode: 'chatgpt', tokens: { access_token: 'TEST_NEW_ACCESS', account_id: 'TEST_NEW' } });
  setFixture(home, 401, '{}');
  runProvider(home);
  const cache = readCache(home);
  assert.equal(cache.windows ?? null, null);
  assert.equal(cache.five_hour ?? null, null);
  assert.equal(cache.seven_day ?? null, null);
  assert.equal(cache.error, 'auth');
});

test('模板 fetch.sh 和 statusline 均使用 GPT 专用 provider 及已知桶声明', () => {
  const fetch = readFileSync(join(ROOT, 'Sources/TokenHUD/providers/gpt/fetch.sh'), 'utf8');
  assert.ok(fetch.includes('gpt-usage-provider.mjs'));
  assert.ok(!fetch.includes('glm-usage-provider.mjs'));
  const statusline = readFileSync(join(ROOT, 'Sources/TokenHUD/mjs/statusline.mjs'), 'utf8');
  assert.ok(/GPT_PROVIDER\s*=\s*join\(HUD_DIR, ['"]gpt-usage-provider\.mjs/.test(statusline));
  const gpt = statusline.split('\n').find(line => line.includes("'GPT':"));
  assert.ok(gpt.includes('provider: GPT_PROVIDER'));
  assert.ok(gpt.includes("five_hour: '5h'"));
  assert.ok(gpt.includes("seven_day: '周'"));
  const manifest = JSON.parse(readFileSync(join(ROOT, 'Sources/TokenHUD/providers/gpt/manifest.json'), 'utf8'));
  assert.equal(manifest.queryUrl, 'https://chatgpt.com/backend-api/wham/usage');
  assert.ok(manifest.buckets.five_hour);
  assert.ok(manifest.buckets.seven_day);
});
