#!/usr/bin/env node
// ClinePass provider 离线回归: stub curl + 临时 HOME, 不触网、不读真实凭证
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
const NODE = process.execPath;

function makeHome() {
  const home = join(tmpdir(), `cline-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  mkdirSync(join(home, '.claude/hud'), { recursive: true });
  mkdirSync(join(home, 'bin'), { recursive: true });
  return home;
}

// 通用 stub curl: 读 $CLINE_TEST_SCRIPT 指向的 shell 片段 (每个用例自定义应答序列)
function installStubCurl(home, scriptBody) {
  const stub = join(home, 'bin/curl');
  writeFileSync(stub, `#!/bin/sh
printf '%s\\n' "$@" >> "$CLINE_TEST_CURLLOG"
${scriptBody}
`, { mode: 0o755 });
  return stub;
}

function writeAuth(home, obj) {
  writeFileSync(join(home, '.claude/hud/.cline-usage-auth.json'), JSON.stringify(obj));
}

function runProvider(home, extra = {}) {
  const env = {
    ...process.env,
    HOME: home,
    USAGE_AUTH_FILE: join(home, '.claude/hud/.cline-usage-auth.json'),
    USAGE_CACHE_FILE: join(home, '.claude/hud/.cline-usage-cache.json'),
    TOKENHUD_CURL: join(home, 'bin/curl'),
    CLINE_TEST_CURLLOG: join(home, 'curl.log'),
    CLINE_TEST_IDX: join(home, 'idx'),
    CLINE_TEST_PLAN: join(home, 'plan'),
    CLINE_TEST_PAGE1: join(home, 'page1'),
    CLINE_TEST_PAGE2: join(home, 'page2'),
    CLINE_TEST_P2DONE: join(home, 'p2done'),
    CLINE_TEST_PAGEIDX: join(home, 'pageidx'),
    CLINE_TEST_PG1: join(home, 'pg1'),
    CLINE_TEST_PG2: join(home, 'pg2'),
    CLINE_TEST_PG3: join(home, 'pg3'),
    ...extra,
  };
  if (process.env.CLINE_TEST_DEBUG) console.error("RUNPROVIDER env CLINE*=", Object.entries(env).filter(([k])=>k.startsWith("CLINE_TEST")).map(([k,v])=>k+"="+(v||"").slice(-20)).join(" "));
  const r = spawnSync(NODE, [PROVIDER], { env, encoding: 'utf8', timeout: 30000 });
  if (process.env.CLINE_TEST_DEBUG) console.error("RUNPROVIDER result status=", r.status, "stderr=", (r.stderr||"").slice(0,120));
  return r;
}

function readCache(home) {
  const p = join(home, '.claude/hud/.cline-usage-cache.json');
  return existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null;
}

const NOW = Date.now();
const H5 = new Date(NOW - 2 * 36e5).toISOString();   // 2h 前
const D3 = new Date(NOW - 3 * 864e5).toISOString();  // 3 天前
const D6 = new Date(NOW - 6 * 864e5).toISOString();  // 6 天前 (7d 窗内)
const D8 = new Date(NOW - 8 * 864e5).toISOString();  // 8 天前 (7d 窗外)

// 标准双页流水: 页1 (200 条新) + 页2 (旧, 8 天前)
function usageItem(at, costUsdMicro, id) {
  return { id, createdAt: at, costUsd: costUsdMicro, creditsUsed: 0, operation: 'chat_completion' };
}
const PAGE1 = Array.from({ length: 200 }, (_, i) => usageItem(H5, 1_000_000, `usg-new-${i}`)); // 5h 内 $200
const PAGE2 = [usageItem(D6, 2_000_000, 'usg-w1'), usageItem(D3, 3_000_000, 'usg-w2'), usageItem(D8, 9_000_000, 'usg-out')];

function planBody() {
  return JSON.stringify({ data: { userId: 'usr-1', plan: { entitlements: { cline_pass: {
    // 测试用小值 cap (micro-USD): 5h=0.2$ 7d=1$ 30d=4$; costUsd 同为 micro-USD
    inferenceCapThreshold: { last5HoursUsageCostUSDPerUser: 200_000, last7daysUsageCostUSDPerUser: 1_000_000, last30daysUsageCostUSDPerUser: 4_000_000 },
  } } }, currentPeriodStart: new Date(NOW - 10 * 864e5).toISOString(), currentPeriodEnd: new Date(NOW + 20 * 864e5).toISOString() }, success: true });
}

test('双窗口百分比: 5h 用量/cap、7d 用量/cap, resets_at=periodEnd', () => {
  const home = makeHome();
  installStubCurl(home, `
case "$*" in
  *users/me*) cat "$CLINE_TEST_PLAN" ;;
  *usages*nextToken=tok1*) cat "$CLINE_TEST_PAGE2" ;;
  *usages*) cat "$CLINE_TEST_PAGE1" ;;
  *) cat "$CLINE_TEST_PAGE1" ;;
esac
printf '\\n200\\n'`);
  writeAuth(home, { apiKey: 'clp_test' });
  writeFileSync(join(home, 'plan'), planBody());
  writeFileSync(join(home, 'page1'), JSON.stringify({ data: { items: PAGE1, nextToken: 'tok1' } }));
  writeFileSync(join(home, 'page2'), JSON.stringify({ data: { items: PAGE2 } }));
  const r = runProvider(home);
  assert.equal(r.status, 0, r.stderr);
  const c = readCache(home);
  // 5h: $200 / cap $0.2 → 封顶 100%; 7d: (200+2+3)/1 → 100% 封顶; 8d 前的 9 不计
  assert.equal(c.five_hour.used_percentage, 100);
  assert.equal(c.seven_day.used_percentage, 100);
  assert.ok(Math.abs(c.seven_day.resets_at - Date.parse(JSON.parse(readFileSync(join(home, 'plan'), 'utf8')).data.currentPeriodEnd) / 1000) < 5, 'resets_at 须为订阅周期末');
  const log = readFileSync(join(home, 'curl.log'), 'utf8');
  assert.ok(log.includes('https://api.cline.bot'), '须请求官方 API');
  assert.ok(log.includes('Bearer clp_test'), '须带 Bearer');
});

test('百分比非封顶: 5h 10%, 7d 30.5%', () => {
  const home = makeHome();
  installStubCurl(home, `
case "$*" in
  *users/me*) cat "$CLINE_TEST_PLAN" ;;
  *usages*nextToken=tok1*) cat "$CLINE_TEST_PAGE2" ;;
  *usages*) cat "$CLINE_TEST_PAGE1" ;;
esac
printf '\\n200\\n'`);
  writeAuth(home, { apiKey: 'clp_test' });
  writeFileSync(join(home, 'plan'), planBody());
  // 5h: $0.02/0.2 = 10%; 7d: 0.02+0.305 = 0.325/1 = 32.5%; page1 nextToken=tok1 驱动分流
  const p1 = Array.from({ length: 2 }, (_, i) => usageItem(H5, 10_000, `n${i}`)); // 2 × $0.01 = $0.02
  writeFileSync(join(home, 'page1'), JSON.stringify({ data: { items: p1, nextToken: 'tok1' } }));
  writeFileSync(join(home, 'page2'), JSON.stringify({ data: { items: [usageItem(D6, 305_000, 'w1')] } })); // $0.305
  runProvider(home);
  const c = readCache(home);
  assert.equal(c.five_hour.used_percentage, 10);
  assert.equal(c.seven_day.used_percentage, 32.5);
});

test('翻页循环: 多页 until 无 nextToken, 上限保护 10 页', () => {
  const home = makeHome();
  installStubCurl(home, `
case "$*" in
  *users/me*) cat "$CLINE_TEST_PLAN" ;;
  *usages*)
    N=$(cat "$CLINE_TEST_PAGEIDX" 2>/dev/null || echo 0)
    I=$((N+1)); echo $I > "$CLINE_TEST_PAGEIDX"
    if [ "$I" -gt 3 ]; then I=3; fi
    if [ "$I" = "1" ]; then cat "$CLINE_TEST_PG1"; fi
    if [ "$I" = "2" ]; then cat "$CLINE_TEST_PG2"; fi
    if [ "$I" = "3" ]; then cat "$CLINE_TEST_PG3"; fi ;;
esac
printf '\\n200\\n'`);
  writeAuth(home, { apiKey: 'clp_test' });
  writeFileSync(join(home, 'plan'), planBody());
  // 3 页后 stub 固定返回页3 (带 nextToken) → provider 须在 10 页上限处停, 不死循环
  writeFileSync(join(home, 'pg1'), JSON.stringify({ data: { items: [usageItem(D6, 100_000, 'p1')], nextToken: 't1' } }));
  writeFileSync(join(home, 'pg2'), JSON.stringify({ data: { items: [usageItem(D6, 100_000, 'p2')], nextToken: 't2' } }));
  writeFileSync(join(home, 'pg3'), JSON.stringify({ data: { items: [usageItem(D6, 100_000, 'p3')], nextToken: 't-loop' } }));
  const t0 = Date.now();
  const r = runProvider(home);
  assert.equal(r.status, 0);
  assert.ok(Date.now() - t0 < 15000, '翻页须有上限, 不得死循环');
  const c = readCache(home);
  console.error("C3DIAG cache=",JSON.stringify(c).slice(0,180)," stderr=",(r.stderr||"").slice(0,200)," log=",(function(){try{return JSON.stringify(readFileSync(join(home,"curl.log"),"utf8"))}catch(e){return "none"}})());
  // pg3 自环 (恒带 nextToken) → provider 翻到 10 页上限: 10 页 × $0.1 / cap $1 = 100%
  assert.equal(c.seven_day.used_percentage, 100, '自环页须被页数上限截断');
});

test('失败保旧: 先成功后 500, 旧桶保留 stale', () => {
  const home = makeHome();
  installStubCurl(home, `
case "$*" in
  *users/me*) cat "$CLINE_TEST_PLAN" ;;
  *usages*) cat "$CLINE_TEST_PAGE1" ;;
esac
CODE=200
if [ "$CLINE_TEST_FAIL" = "1" ]; then CODE=500; printf '{}'; printf '\\n%s\\n' "$CODE"; exit 0; fi
printf '\\n%s\\n' "$CODE"`);
  writeAuth(home, { apiKey: 'clp_test' });
  writeFileSync(join(home, 'plan'), planBody());
  writeFileSync(join(home, 'page1'), JSON.stringify({ data: { items: [usageItem(H5, 100_000, 'a')] } }));
  runProvider(home);
  let c = readCache(home);
  assert.equal(c.five_hour.used_percentage, 50);

  writeFileSync(join(home, 'idx'), ''); // 复位 stub 序号
  runProvider(home, { CLINE_TEST_FAIL: '1' });
  c = readCache(home);
  assert.equal(c.five_hour.used_percentage, 50, '失败不得清旧桶');
  assert.equal(c.stale, true);
  assert.ok(c.error);
});

test('凭证缺失 → no-auth 不发请求; 401 → auth', () => {
  const home = makeHome();
  installStubCurl(home, `printf '{}'; printf '\\n401\\n'`);
  runProvider(home);
  assert.equal(readCache(home).error, 'no-auth');
  assert.ok(!existsSync(join(home, 'curl.log')), 'no-auth 不发请求');

  writeAuth(home, { apiKey: 'clp_expired' });
  runProvider(home);
  assert.equal(readCache(home).error, 'auth');
});

test('不写外部凭证; auth 文件可含说明键', () => {
  const home = makeHome();
  installStubCurl(home, `
case "$*" in
  *users/me*) cat "$CLINE_TEST_PLAN" ;;
  *usages*) cat "$CLINE_TEST_PAGE1" ;;
esac
printf '\\n200\\n'`);
  writeAuth(home, { apiKey: 'clp_test', _note: '说明文字', apiUrl: 'https://api.cline.bot' });
  writeFileSync(join(home, 'plan'), planBody());
  writeFileSync(join(home, 'page1'), JSON.stringify({ data: { items: [usageItem(H5, 100_000, 'a')] } }));
  const r = runProvider(home);
  assert.equal(r.status, 0);
  assert.equal(readCache(home).five_hour.used_percentage, 50);
});

test('模板路由: fetch.sh 与 statusline 均指向 cline-usage-provider', () => {
  const fetchSh = readFileSync(join(ROOT, 'Sources/TokenHUD/providers/cline/fetch.sh'), 'utf8');
  assert.ok(fetchSh.includes('cline-usage-provider.mjs'));
  const sl = readFileSync(join(ROOT, 'Sources/TokenHUD/mjs/statusline.mjs'), 'utf8');
  const line = sl.split('\n').find(l => l.includes("'Cline'"));
  assert.ok(line && line.includes('provider: CLINE_PROVIDER'));
  const manifest = JSON.parse(readFileSync(join(ROOT, 'Sources/TokenHUD/providers/cline/manifest.json'), 'utf8'));
  assert.ok(manifest.buckets.five_hour);
});
