#!/usr/bin/env node
// Ollama Cloud 用量 provider: /api/balance (Bearer key -> remaining_percent)
// 2026-10: /api/usage 移除 limits 字段（改为 buckets 请求统计），限额迁至 /api/balance
// legacy plan 返回 included.session/weekly.remaining_percent (0~100) + resets_at
// 新计费 plan 返回 included.balance_usd/allowance_usd — 主框架按美元额度处理
// fetch: curl 子进程 (绝对路径). node 内置 fetch (undici) 在 TUN fake-IP 代理环境连不通, curl 可通
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const HUD_DIR = join(CLAUDE_DIR, 'hud');
const AUTH_FILE = process.env.USAGE_AUTH_FILE || join(HUD_DIR, '.ollama-usage-auth.json');
const CACHE_FILE = process.env.USAGE_CACHE_FILE || join(HUD_DIR, '.ollama-usage-cache.json');
const TTL_MS = 60_000;
const verbose = !!process.env.USAGE_VERBOSE;
const DEFAULT_URL = 'https://ollama.com/api/balance';

const readJson = (p, def) => {
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return def; }
};
const writeCache = (obj) => {
  try { mkdirSync(HUD_DIR, { recursive: true }); writeFileSync(CACHE_FILE, JSON.stringify(obj, null, 2)); } catch {}
};
// 失败通用出口: 旧缓存有数据则保留 (UI 用上一轮), 仅无旧数据才写错误态
// generatedAt = 最近成功快照时间: 失败不推进, 只前移 lastAttemptAt (FR-03.8)
const writeFailure = (kind, detail) => {
  const prev = readJson(CACHE_FILE, null);
  const now = Date.now();
  if (prev && (prev.five_hour || prev.seven_day)) {
    writeCache({ ...prev, error: kind, stale: true, lastAttemptAt: now });
  } else {
    writeCache({ error: kind, lastAttemptAt: now, ttlMs: TTL_MS, stale: true });
  }
  if (verbose) console.error(`[ollama-provider] ${kind}: ${detail}`);
};

function curlJson(url, key) {
  const r = spawnSync('/usr/bin/curl', [
    '-sS', '--connect-timeout', '8', '--max-time', '12',
    '-H', `Authorization: Bearer ${key}`, '-H', 'Accept: application/json',
    '-w', '\n%{http_code}',
    url,
  ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  if (r.error || r.status !== 0 || !r.stdout) {
    return { err: r.error?.message || ('exit ' + r.status) };
  }
  const nl = r.stdout.lastIndexOf('\n');
  const status = parseInt(r.stdout.slice(nl + 1).trim(), 10);
  return { status, text: r.stdout.slice(0, nl) };
}

async function main() {
  const auth = readJson(AUTH_FILE, null);
  const h = (auth && auth.headers) || {};
  const bearer = String(h.Authorization || '').replace(/^Bearer\s+/i, '');
  const key = bearer || String((auth && auth.refreshApiKey) || '');
  if (!key) {
    writeCache({ error: 'no-auth', generatedAt: Date.now(), ttlMs: TTL_MS });
    if (verbose) console.error('[ollama-provider] missing Bearer key');
    return;
  }
  const url = (auth.apiUrl && auth.apiUrl.includes('/api/balance')) ? auth.apiUrl : DEFAULT_URL;

  // 单次尝试: App 每 60s 一轮即天然重试; 内重试会与下一轮叠加致请求量超 10 req/min 限频
  let text = null, lastErr = 'unknown';
  const { status, text: body, err } = curlJson(url, key);
  if (err) { lastErr = err; }
  else if (status === 200 && body) { text = body; }
  else if (status === 429) { writeFailure('ratelimit', 'HTTP 429'); return; }
  else { lastErr = 'HTTP ' + status + ' ' + String(body).slice(0, 80); }
  if (!text) {
    writeFailure('network', lastErr);
    return;
  }

  let data;
  try { data = JSON.parse(text); } catch {
    writeFailure('parse', 'non-JSON: ' + text.slice(0, 120));
    return;
  }
  if (data && (data.error === 'too many requests' || data.error === 'invalid credentials')) {
    writeFailure(data.error, 'ollama: ' + data.error);
    return;
  }
  const included = data && data.included;
  if (!included) {
    writeFailure('parse', 'no included: ' + text.slice(0, 120));
    return;
  }
  // legacy plan: included.session/weekly.remaining_percent (0~100 剩余) -> used_percentage (已用)
  const pct = (b) => (b && typeof b.remaining_percent === 'number') ? {
    used_percentage: Math.round((100 - b.remaining_percent) * 10) / 10,
    resets_at: b.resets_at || null,
  } : null;
  const legacy = pct(included.session) || pct(included.weekly);
  if (legacy) {
    writeCache({
      five_hour: pct(included.session),
      seven_day: pct(included.weekly),
      monthly: null,
      generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false,
    });
    if (verbose) console.error('[ollama-provider] ok (legacy)');
    return;
  }
  // 新计费 plan: included.balance_usd/allowance_usd + period -> 月度额度桶 (已用百分比 + 周期重置)
  if (typeof included.allowance_usd === 'number' && typeof included.balance_usd === 'number') {
    const usedPct = included.allowance_usd > 0
      ? Math.round((1 - included.balance_usd / included.allowance_usd) * 1000) / 10
      : 0;
    const resets = included.period?.until ? Math.floor(Date.parse(included.period.until) / 1000) : null;
    writeCache({
      five_hour: null,
      seven_day: null,
      monthly: { used_percentage: usedPct, resets_at: resets || null },
      generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false,
    });
    if (verbose) console.error(`[ollama-provider] ok (credit: $${included.balance_usd}/$${included.allowance_usd})`);
    return;
  }
  writeFailure('parse', 'unknown plan shape: ' + text.slice(0, 120));
}

main().catch(e => writeFailure('network', String(e?.message || e)));
