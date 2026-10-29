#!/usr/bin/env node
// ClinePass 用量 provider: 官方 usage-limits 接口 (凭证: app.cline.bot/settings/api-keys)
// GET https://api.cline.bot/api/v1/users/me/plan/usage-limits
//   → { data: { limits: [{ type: "five_hour"|"weekly"|"monthly", percentUsed, resetsAt }] } }
// percentUsed 已是百分数, resetsAt 是 ISO8601 → 转 epoch 秒
// 单次请求, 10s 上限; 凭证只读不写回; 失败保旧桶; 未知 type 忽略不猜
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const HUD_DIR = join(CLAUDE_DIR, 'hud');
const AUTH_FILE = process.env.USAGE_AUTH_FILE || join(HUD_DIR, '.cline-usage-auth.json');
const CACHE_FILE = process.env.USAGE_CACHE_FILE || join(HUD_DIR, '.cline-usage-cache.json');
const API_BASE = 'https://api.cline.bot';
const TIMEOUT_S = 8;   // 单次请求上限; 最多两次 = 16s, 留余量给 ProviderRunner 20s 上限
const TTL_MS = 60_000;
const verbose = !!process.env.USAGE_VERBOSE;
const CURL = process.env.TOKENHUD_CURL || '/usr/bin/curl';

// 接口 type → 缓存桶名; 不在表内的 type 忽略
const TYPE_MAP = { five_hour: 'five_hour', weekly: 'seven_day', monthly: 'monthly' };

const readJson = (p) => {
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; }
};
const writeCache = (obj) => {
  try { mkdirSync(HUD_DIR, { recursive: true }); writeFileSync(CACHE_FILE, JSON.stringify(obj, null, 2)); } catch {}
};
// 失败通用出口: 旧缓存有桶则保留 (UI 用上一轮), 仅无旧数据才写错误态
const writeFailure = (kind, detail) => {
  const prev = readJson(CACHE_FILE);
  if (prev && (prev.five_hour || prev.seven_day || prev.monthly)) {
    writeCache({ ...prev, error: kind, stale: true, generatedAt: Date.now() });
  } else {
    writeCache({ error: kind, detail: String(detail || '').slice(0, 140), generatedAt: Date.now(), ttlMs: TTL_MS, stale: true });
  }
  if (verbose) console.error(`[cline-provider] ${kind}: ${detail}`);
};

// GET 一次; 返回 {status, json} 或 {err}
function getOnce(url, key) {
  const r = spawnSync(CURL, [
    '-sS', '--connect-timeout', '6', '--max-time', String(TIMEOUT_S),
    '-H', `Authorization: Bearer ${key}`,
    '-H', 'Accept: application/json',
    '-w', '\n%{http_code}',
    url,
  ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
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

// 连接层失败 (无 HTTP 应答, 如 TLS exit 35) 重试一次; 有应答不重试
function getJson(url, key) {
  const first = getOnce(url, key);
  if (!first.err || first.status) return first;
  return getOnce(url, key);
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
  if (!key) {
    writeFailure('no-auth', '缺 apiKey (app.cline.bot/settings/api-keys)');
    return;
  }

  const res = getJson(`${API_BASE}/api/v1/users/me/plan/usage-limits`, key);
  if (res.err) { writeFailure(res.err === 'non-JSON' ? 'parse' : 'network', res.err); return; }
  if (res.status === 401 || res.status === 403) {
    writeFailure('auth', `HTTP ${res.status}: 凭证过期, 请到 app.cline.bot 重新生成`);
    return;
  }
  if (res.status !== 200) { writeFailure('network', `HTTP ${res.status}`); return; }

  const limits = res.json?.data?.limits;
  if (!Array.isArray(limits)) { writeFailure('parse', '响应无 data.limits'); return; }

  const buckets = { five_hour: null, seven_day: null, monthly: null };
  for (const item of limits) {
    const slot = TYPE_MAP[item?.type];
    if (!slot) continue;
    const pct = item.percentUsed;
    if (typeof pct !== 'number' || !Number.isFinite(pct)) continue;
    buckets[slot] = {
      used_percentage: Math.round(Math.min(100, Math.max(0, pct)) * 10) / 10,
      resets_at: toEpochSec(item.resetsAt),
    };
  }
  if (!buckets.five_hour && !buckets.seven_day && !buckets.monthly) {
    writeFailure('parse', 'usage-limits 无已知额度桶');
    return;
  }

  writeCache({ ...buckets, generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false });
  if (verbose) console.error('[cline-provider] ok');
}

main();
