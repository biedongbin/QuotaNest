#!/usr/bin/env node
// ClinePass 用量 provider: 官方 usage-limits 接口 (凭证: app.cline.bot/settings/api-keys)
// GET https://api.cline.bot/api/v1/users/me/plan/usage-limits
//   → { data: { limits: [{ type: "five_hour"|"weekly"|"monthly", percentUsed, resetsAt }] } }
// percentUsed 已是百分数, resetsAt 是 ISO8601 → 转 epoch 秒
// 无 ClinePass (404) 时读取独立充值余额；整次查询 18s；凭证只读，重试由 Runner 负责
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const HUD_DIR = process.env.TOKENHUD_HUD_DIR || join(CLAUDE_DIR, 'hud');
const AUTH_FILE = process.env.TOKENHUD_AUTH_FILE || process.env.USAGE_AUTH_FILE || join(HUD_DIR, '.cline-usage-auth.json');
const CACHE_FILE = process.env.TOKENHUD_CACHE_FILE || process.env.USAGE_CACHE_FILE || join(HUD_DIR, '.cline-usage-cache.json');
const API_BASE = 'https://api.cline.bot';
const TIMEOUT_S = 18;
const deadline = Date.now() + 18_000;
const CLIENT_HEADERS = {
  'HTTP-Referer': 'https://cline.bot', 'X-Title': 'Cline', 'X-IS-MULTIROOT': 'false',
  'X-CLIENT-TYPE': 'cline-desktop', 'X-CLIENT-VERSION': '3.5.54', 'User-Agent': 'Cline/3.5.54',
};
const TTL_MS = 60_000;
const verbose = !!process.env.USAGE_VERBOSE;
const CURL = process.env.TOKENHUD_CURL || '/usr/bin/curl';

// 接口 type → 缓存桶名; 不在表内的 type 忽略
const TYPE_MAP = { five_hour: 'five_hour', weekly: 'seven_day', monthly: 'monthly' };
// P1-11 动态窗口: 接口 type → 中文窗口 label
const TYPE_LABEL = { five_hour: '5小时', weekly: '本周', monthly: '本月' };

const readJson = (p) => {
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; }
};
const writeCache = (obj) => {
  if (process.env.TOKENHUD_STDOUT_ONLY === '1') {
    process.stdout.write(JSON.stringify(obj) + '\n');
    return;
  }
  try { mkdirSync(HUD_DIR, { recursive: true }); writeFileSync(CACHE_FILE, JSON.stringify(obj, null, 2)); } catch {}
};
// 失败通用出口: 旧缓存有桶则保留 (UI 用上一轮), 仅无旧数据才写错误态
// generatedAt = 最近成功快照时间: 失败不推进, 只前移 lastAttemptAt (FR-03.8)
const writeFailure = (kind, detail) => {
  const prev = readJson(CACHE_FILE);
  const now = Date.now();
  if (prev && (prev.five_hour || prev.seven_day || prev.monthly || prev.windows?.length)) {
    writeCache({ ...prev, error: kind, stale: true, lastAttemptAt: now });
  } else {
    writeCache({ error: kind, detail: String(detail || '').slice(0, 140), lastAttemptAt: now, ttlMs: TTL_MS, stale: true });
  }
  if (verbose) console.error(`[cline-provider] ${kind}: ${detail}`);
};

// GET 一次; 返回 {status, json} 或 {err}
function getJson(url, key) {
  const remaining = Math.min(TIMEOUT_S, (deadline - Date.now()) / 1000);
  if (remaining <= 0) return { err: 'deadline' };
  const r = spawnSync(CURL, [
    '-q', '-sS', '--http1.1', '--connect-timeout', String(Math.min(4, remaining)), '--max-time', String(remaining),
    '--proto', '=https',
    '-H', `Authorization: Bearer ${key}`,
    '-H', 'Accept: application/json',
    ...Object.entries(CLIENT_HEADERS).flatMap(([name, value]) => ['-H', `${name}: ${value}`]),
    '-w', '\n%{http_code}',
    url,
  ], { encoding: 'utf8', timeout: Math.max(1, Math.floor(remaining * 1000)),
       killSignal: 'SIGKILL', maxBuffer: 2_000_000, stdio: ['ignore', 'pipe', 'pipe'] });
  if (r.error || r.status !== 0 || !r.stdout) {
    return { err: r.error?.message || `exit ${r.status}` };
  }
  const out = r.stdout.trimEnd();
  const sep = out.lastIndexOf('\n');
  const status = parseInt(out.slice(sep + 1).trim(), 10);
  let json = null;
  try { json = JSON.parse(out.slice(0, sep)); } catch { return { err: 'non-JSON', status }; }
  return { status, json };
}

function failureKind(response) {
  if (response.err) return response.err === 'non-JSON' ? 'parse' : 'network';
  if ([401, 403].includes(response.status)) return 'auth';
  if (response.status === 429) return 'ratelimit';
  if (response.status !== 200) return 'network';
  if (response.json?.success === false || response.json?.error) return 'api';
  return null;
}

function creditBalance(key) {
  const me = getJson(`${API_BASE}/api/v1/users/me`, key);
  const meError = failureKind(me);
  if (meError) return { error: meError };
  const identity = me.json?.data ?? me.json;
  const ids = [...new Set([identity?.clineUserId, identity?.subject, identity?.id]
    .filter(value => typeof value === 'string' && value.trim() && !/[\r\n\0]/.test(value)))];
  if (!ids.length) return { error: 'parse' };
  let error = 'parse';
  for (const id of ids) {
    const reply = getJson(`${API_BASE}/api/v1/users/${encodeURIComponent(id)}/balance`, key);
    error = failureKind(reply);
    if (error) {
      if (reply.status === 404) continue;
      return { error };
    }
    const raw = (reply.json?.data ?? reply.json)?.balance;
    const microdollars = typeof raw === 'number' || typeof raw === 'string' && raw.trim() ? Number(raw) : NaN;
    if (!Number.isFinite(microdollars) || microdollars < 0) return { error: 'parse' };
    return { windows: [{ label: '充值余额', amount: microdollars / 1_000_000, unit: 'USD', period: 'balance' }] };
  }
  return { error: error || 'parse' };
}

// ISO8601 (可带 9 位纳秒小数) → epoch 秒; 非法返回 null
function toEpochSec(iso) {
  if (typeof iso !== 'string' || !iso) return null;
  // 小数位裁到 3 位: 部分解析器不接受纳秒
  const trimmed = iso.replace(/(\.\d{3})\d+/, '$1');
  const ms = Date.parse(trimmed);
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : null;
}

function main() {
  const auth = readJson(AUTH_FILE) || {};
  const key = String(auth.apiKey || '').trim();
  if (!key || /[\r\n\0]/.test(key)) {
    writeFailure('no-auth', '缺 apiKey (app.cline.bot/settings/api-keys)');
    return;
  }

  const res = getJson(`${API_BASE}/api/v1/users/me/plan/usage-limits`, key);
  if (res.status === 404) {
    const credit = creditBalance(key);
    if (credit.error) { writeFailure(credit.error, 'ClinePass 未订阅，充值余额暂不可读取'); return; }
    writeCache({ five_hour: null, seven_day: null, monthly: null, windows: credit.windows,
      generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false,
      message: '未订阅 ClinePass；此处为独立充值余额' });
    return;
  }
  if (res.err) { writeFailure(res.err === 'non-JSON' ? 'parse' : 'network', res.err); return; }
  if (res.status === 401 || res.status === 403) {
    writeFailure('auth', `HTTP ${res.status}: 凭证过期, 请到 app.cline.bot 重新生成`);
    return;
  }
  if (res.status === 429) { writeFailure('ratelimit', `HTTP 429`); return; }
  if (res.status !== 200) { writeFailure('network', `HTTP ${res.status}`); return; }

  const limits = res.json?.data?.limits;
  if (!Array.isArray(limits)) { writeFailure('parse', '响应无 data.limits'); return; }

  const buckets = { five_hour: null, seven_day: null, monthly: null };
  const windows = [];
  for (const item of limits) {
    const slot = TYPE_MAP[item?.type];
    if (!slot) continue;
    const pct = item.percentUsed;
    if (typeof pct !== 'number' || !Number.isFinite(pct)) continue;
    const clamped = Math.round(Math.min(100, Math.max(0, pct)) * 10) / 10;
    const resetsAt = toEpochSec(item.resetsAt);
    buckets[slot] = { used_percentage: clamped, resets_at: resetsAt };
    windows.push({ label: TYPE_LABEL[item.type], used_percentage: clamped, resets_at: resetsAt });
  }
  if (!buckets.five_hour && !buckets.seven_day && !buckets.monthly) {
    writeFailure('parse', 'usage-limits 无已知额度桶');
    return;
  }

  writeCache({ ...buckets, windows, generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false });
  if (verbose) console.error('[cline-provider] ok');
}

main();
