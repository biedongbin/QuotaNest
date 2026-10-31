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
import { normalizeUsage, epochSeconds } from './usage-normalize.mjs';
import { parseOllamaHTML } from './provider-web-parsing.mjs';

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const HUD_DIR = process.env.TOKENHUD_HUD_DIR || join(CLAUDE_DIR, 'hud');
const AUTH_FILE = process.env.TOKENHUD_AUTH_FILE || process.env.USAGE_AUTH_FILE || join(HUD_DIR, '.ollama-usage-auth.json');
const CACHE_FILE = process.env.TOKENHUD_CACHE_FILE || process.env.USAGE_CACHE_FILE || join(HUD_DIR, '.ollama-usage-cache.json');
const TTL_MS = 60_000;
const verbose = !!process.env.USAGE_VERBOSE;
const DEFAULT_URL = 'https://ollama.com/api/balance';

const readJson = (p, def) => {
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return def; }
};
const writeCache = (obj) => {
  if (process.env.TOKENHUD_STDOUT_ONLY === '1') {
    process.stdout.write(JSON.stringify(obj) + '\n');
    return;
  }
  try { mkdirSync(HUD_DIR, { recursive: true }); writeFileSync(CACHE_FILE, JSON.stringify(obj, null, 2)); } catch {}
};
// 失败通用出口: 旧缓存有数据则保留 (UI 用上一轮), 仅无旧数据才写错误态
// generatedAt = 最近成功快照时间: 失败不推进, 只前移 lastAttemptAt (FR-03.8)
const writeFailure = (kind, detail) => {
  const prev = readJson(CACHE_FILE, null);
  const now = Date.now();
  if (prev && (prev.five_hour || prev.seven_day || prev.monthly || prev.windows?.length)) {
    writeCache({ ...prev, error: kind, stale: true, lastAttemptAt: now });
  } else {
    writeCache({ error: kind, lastAttemptAt: now, ttlMs: TTL_MS, stale: true });
  }
  if (verbose) console.error(`[ollama-provider] ${kind}: ${detail}`);
};

// 测试注入口: 正常路径恒为 /usr/bin/curl
const CURL = process.env.TOKENHUD_CURL || '/usr/bin/curl';

function curlJson(url, credentialHeader, cookieMode = false) {
  const r = spawnSync(CURL, [
    '-sS', '--connect-timeout', '8', '--max-time', '12', '--proto', '=https,http',
    '-H', credentialHeader, '-H', cookieMode ? 'Accept: text/html,application/xhtml+xml' : 'Accept: application/json',
    ...(cookieMode ? ['-H', 'Origin: https://ollama.com', '-H', 'Referer: https://ollama.com/settings',
      '-H', 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/143.0.0.0 Safari/537.36'] : []),
    '-w', '\n%{http_code}',
    '--url', url,
  ], { encoding: 'utf8', timeout: 15000, maxBuffer: 2_000_000, stdio: ['ignore', 'pipe', 'pipe'] });
  if (r.error || r.status !== 0 || !r.stdout) {
    return { err: r.error?.message || ('exit ' + r.status) };
  }
  const nl = r.stdout.lastIndexOf('\n');
  const status = parseInt(r.stdout.slice(nl + 1).trim(), 10);
  return { status, text: r.stdout.slice(0, nl) };
}

async function main() {
  const auth = readJson(AUTH_FILE, null) || {};
  const h = auth.headers || {};
  const bearer = String(h.Authorization || '').replace(/^Bearer\s+/i, '');
  const key = String(auth.queryKey ?? (bearer || auth.refreshApiKey || '')).trim();
  const cookie = String(auth.cookieAuth || '').trim();
  if ((!cookie && !key) || /[\r\n]/.test(cookie || key)) {
    writeFailure('no-auth', 'missing query credential');
    return;
  }
  const configured = process.env.TOKENHUD_QUERY_URL || auth.queryUrl || auth.apiUrl;
  // Keep the legacy /api/usage auth-template compatible with the known balance adapter.
  const url = cookie ? 'https://ollama.com/settings'
    : (configured && configured.includes('/api/balance') ? configured : DEFAULT_URL);
  const header = cookie ? `Cookie: ${cookie}` : `Authorization: Bearer ${key}`;

  // 单次尝试: App 每 60s 一轮即天然重试; 内重试会与下一轮叠加致请求量超 10 req/min 限频
  let text = null, lastErr = 'unknown';
  const { status, text: body, err } = curlJson(url, header, !!cookie);
  if (err) { lastErr = err; }
  else if (status === 200 && body) { text = body; }
  else if ((status === 401 || status === 403) || (cookie && [301, 302, 303, 307, 308].includes(status))) { writeFailure('auth', `HTTP ${status}`); return; }
  else if (status === 429) { writeFailure('ratelimit', 'HTTP 429'); return; }
  else { lastErr = 'HTTP ' + status; }
  if (!text) {
    writeFailure('network', lastErr);
    return;
  }

  if (cookie) {
    const usage = parseOllamaHTML(text);
    if (usage?.error) { writeFailure(usage.error, 'signed-out settings page'); return; }
    if (usage) {
      writeCache({ ...usage, generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false });
      return;
    }
  }
  let data;
  try { data = JSON.parse(text); } catch {
    writeFailure('parse', cookie ? 'unrecognized usage page' : 'non-JSON response');
    return;
  }
  const normalized = normalizeUsage(data);
  if (normalized && !data.error) {
    writeCache({ ...normalized, generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false });
    return;
  }
  if (data && (data.error === 'too many requests' || data.error === 'invalid credentials')) {
    writeFailure(data.error, 'ollama: ' + data.error);
    return;
  }
  const included = data && data.included;
  if (!included) {
    writeFailure('parse', 'no included balance data');
    return;
  }
  // legacy plan: included.session/weekly.remaining_percent (0~100 剩余) -> used_percentage (已用)
  const pct = (b) => (b && typeof b.remaining_percent === 'number') ? {
    used_percentage: Math.round((100 - b.remaining_percent) * 10) / 10,
    resets_at: epochSeconds(b.resets_at),
  } : null;
  const legacy = pct(included.session) || pct(included.weekly);
  if (legacy) {
    const five = pct(included.session), seven = pct(included.weekly);
    // P1-11 动态窗口: 5小时/本周 (legacy 形态)
    const windows = [
      five && { label: '5小时', ...five },
      seven && { label: '本周', ...seven },
    ].filter(Boolean);
    writeCache({
      five_hour: five,
      seven_day: seven,
      monthly: null,
      windows,
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
    const resets = epochSeconds(included.period?.until);
    // P1-11 动态窗口: 本月美元额度 (amount/limit/unit/period 按形态上报)
    const windows = [{
      label: '本月', used_percentage: usedPct, resets_at: resets || null,
      amount: Math.round((included.allowance_usd - included.balance_usd) * 100) / 100,
      limit: included.allowance_usd, unit: 'USD',
      period: included.period?.type ? String(included.period.type) : undefined,
    }];
    writeCache({
      five_hour: null,
      seven_day: null,
      monthly: { used_percentage: usedPct, resets_at: resets || null },
      windows,
      generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false,
    });
    if (verbose) console.error(`[ollama-provider] ok (credit: $${included.balance_usd}/$${included.allowance_usd})`);
    return;
  }
  writeFailure('parse', 'unknown plan shape');
}

main().catch(e => writeFailure('network', String(e?.message || e)));
