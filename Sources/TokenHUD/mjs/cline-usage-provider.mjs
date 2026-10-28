#!/usr/bin/env node
// ClinePass 用量 provider: 官方 api.cline.bot (凭证: app.cline.bot/settings/api-keys)
// 模型: 滚动窗口用量 vs 套餐上限 (plan.entitlements.cline_pass.inferenceCapThreshold,
// micro-USD): primary 5h / secondary 7d → five_hour / seven_day 桶
// 用量 = 汇总 usages 流水 costUsd (micro-USD), nextToken 翻页
// 预算: 全程 ≤12s (ProviderRunner 20s 上限内), 超预算即用已汇总部分 (重试由下轮轮询天然完成)
// 凭证只读不写回; 失败保旧同账号额度; 无有效窗口不伪造 0%
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const HUD_DIR = join(CLAUDE_DIR, 'hud');
const AUTH_FILE = process.env.USAGE_AUTH_FILE || join(HUD_DIR, '.cline-usage-auth.json');
const CACHE_FILE = process.env.USAGE_CACHE_FILE || join(HUD_DIR, '.cline-usage-cache.json');
const API_BASE = 'https://api.cline.bot';
const TIMEOUT_S = 10;   // 单请求上限
const BUDGET_MS = 12_000; // 全程预算 (provider 内), 余量留给 fetch.sh cat 与 runner
const MAX_PAGES = 10;   // 翻页上限: 防上游游标异常死循环
const TTL_MS = 60_000;
const verbose = !!process.env.USAGE_VERBOSE;
const CURL = process.env.TOKENHUD_CURL || '/usr/bin/curl';

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

const startedAt = Date.now();
const budgetLeft = () => BUDGET_MS - (Date.now() - startedAt);

// GET 一次; 返回 {status, json} 或 {err}
function getJson(url, key) {
  const left = Math.max(2, Math.ceil(budgetLeft() / 1000));
  const r = spawnSync(CURL, [
    '-sS', '--connect-timeout', '6', '--max-time', String(Math.min(TIMEOUT_S, left)),
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

function main() {
  const auth = readJson(AUTH_FILE) || {};
  const key = String(auth.apiKey || '').trim();
  if (!key) {
    writeFailure('no-auth', '缺 apiKey (app.cline.bot/settings/api-keys)');
    return;
  }

  // 1) plan: 上限 + 周期 + userId
  const plan = getJson(`${API_BASE}/api/v1/users/me/plan`, key);
  if (plan.err) { writeFailure(plan.err === 'non-JSON' ? 'parse' : 'network', plan.err); return; }
  if (plan.status === 401 || plan.status === 403) { writeFailure('auth', `HTTP ${plan.status}: 凭证过期, 请到 app.cline.bot 重新生成`); return; }
  if (plan.status !== 200) { writeFailure('network', `plan HTTP ${plan.status}`); return; }
  const pdata = plan.json.data || plan.json || {};
  const caps = pdata.plan?.entitlements?.cline_pass?.inferenceCapThreshold || {};
  const periodEnd = pdata.currentPeriodEnd ? Math.floor(Date.parse(pdata.currentPeriodEnd) / 1000) : null;
  const userId = pdata.userId;
  if (!userId) { writeFailure('parse', 'plan 响应无 userId'); return; }

  // 2) 一次翻页序列, 同时累计 5h 与 7d (5h 窗 ⊂ 7d 窗)
  const now = Date.now();
  const since5 = now - 5 * 3600 * 1000;
  const since7 = now - 7 * 86400 * 1000;
  let sum5 = 0, sum7 = 0, cursor = '', pages = 0, pagesErr = null;
  while (pages < MAX_PAGES) {
    if (budgetLeft() <= 2000) break;
    const q = `/api/v1/users/${userId}/usages?limit=200${cursor ? `&nextToken=${encodeURIComponent(cursor)}` : ''}`;
    const { status, json, err } = getJson(API_BASE + q, key);
    if (err || status !== 200) { pagesErr = err || `HTTP ${status}`; break; }
    const items = (json.data?.items || json.items || []);
    const data = json.data || json;
    for (const it of items) {
      const t = Date.parse(it.createdAt || '');
      if (!Number.isFinite(t)) continue;
      const c = typeof it.costUsd === 'number' ? it.costUsd : 0;
      if (t >= since7) sum7 += c;
      if (t >= since5) sum5 += c;
    }
    pages++;
    cursor = data.nextToken || '';
    if (!cursor || !items.length) break;
    const oldest = Date.parse(items[items.length - 1].createdAt || '');
    if (Number.isFinite(oldest) && oldest < since7) break;
  }
  // 翻页中断: 已有部分数据则降级使用 (best-effort), 完全无数据才报错
  if (pagesErr && pages === 1) { writeFailure(pagesErr.startsWith('HTTP 40') ? 'auth' : 'network', pagesErr); return; }

  // 3) 百分比 = 窗口用量 / 套餐上限 (同单位 micro-USD); cap 缺失不伪造
  const pct = (used, cap) => {
    if (typeof cap !== 'number' || cap <= 0) return null;
    return Math.round(Math.min(100, (used / cap) * 100) * 10) / 10;
  };
  const fiveHour = pct(sum5, caps.last5HoursUsageCostUSDPerUser);
  const sevenDay = pct(sum7, caps.last7daysUsageCostUSDPerUser);
  if (fiveHour == null && sevenDay == null) {
    writeFailure('parse', '套餐无 inferenceCapThreshold 上限');
    return;
  }
  writeCache({
    five_hour: fiveHour == null ? null : { used_percentage: fiveHour, resets_at: periodEnd },
    seven_day: sevenDay == null ? null : { used_percentage: sevenDay, resets_at: periodEnd },
    monthly: null,
    generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false,
  });
  if (verbose) console.error('[cline-provider] ok');
}

main();
