#!/usr/bin/env node
// API facts checked against local Magpie planquota/presets/commandcode_plan and
// 9router usage/registry sources. Independent TokenHUD implementation; no vendor auth discovery.
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const num = v => v == null || typeof v === 'boolean' || (typeof v === 'string' && !v.trim()) ? null : Number.isFinite(Number(v)) ? Number(v) : null;
const camel = s => s.replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase());
const field = (o, k) => o?.[k] ?? o?.[camel(k)];
const pct = n => Math.max(0, Math.min(100, n));
export function resetSeconds(v) {
  const n = num(v);
  if (n != null) return n > 0 ? Math.floor(n >= 1e12 ? n / 1000 : n) : null;
  const t = typeof v === 'string' ? Date.parse(v) : NaN;
  return Number.isFinite(t) ? Math.floor(t / 1000) : null;
}
const resetOf = o => resetSeconds(o?.resetTime ?? o?.resetAt ?? o?.reset_at ?? o?.reset_time);
function window(label, period, used, limit, reset, unit = 'count', percentage = null) {
  const w = { label, period, resets_at: reset };
  if (used != null) w.amount = used;
  if (limit != null) w.limit = limit;
  if (used != null || limit != null) w.unit = unit;
  const p = percentage ?? (used != null && limit > 0 ? used / limit * 100 : null);
  if (p != null) { w.used_percentage = pct(p); w.remaining_percentage = 100 - pct(p); }
  return w;
}
function counted(o, label, period) {
  const limit = num(o?.limit), remaining = num(o?.remaining);
  const used = num(o?.used) ?? (limit != null && remaining != null ? limit - remaining : null);
  return used == null && limit == null ? null : window(label, period, used, limit, resetOf(o));
}
function output(windows, plan, primaryWindows = windows) {
  const result = { windows };
  if (typeof plan === 'string' && plan) result.plan = plan;
  for (const [period, key] of [['5h', 'five_hour'], ['7d', 'seven_day'], ['month', 'monthly']]) {
    const w = primaryWindows.find(x => x.period === period && x.used_percentage != null);
    if (w) result[key] = { used_percentage: w.used_percentage, resets_at: w.resets_at };
  }
  return result;
}
export function parseZai(body) {
  if (body?.success === false || !Array.isArray(body?.data?.limits)) throw new Error('parse');
  const windows = [];
  for (const l of body.data.limits) {
    const p = num(l.percentage);
    if (p == null) continue;
    const type = String(l.type).toUpperCase(), unit = num(l.unit);
    if (!['TOKENS_LIMIT', 'CREDIT_LIMIT', 'TIME_LIMIT'].includes(type)) continue;
    const hours = num(l.number) > 0 ? num(l.number) : 5;
    const period = type === 'TIME_LIMIT' ? 'month' : unit === 6 ? '7d' : unit === 3 ? `${hours}h` : 'unknown';
    windows.push(window(type === 'TIME_LIMIT' ? 'MCP 月额度' : period, period, null, null,
      resetSeconds(l.nextResetTime), 'count', p));
  }
  return output(windows, body.data.level, windows.filter(w => w.label !== 'MCP 月额度'));
}
export function parseMiniMax(body, endpoint = 'token_plan') {
  const base = body?.base_resp ?? body?.baseResp;
  if (!base || num(field(base, 'status_code')) !== 0) throw new Error('api');
  const rows = body.model_remains ?? body.modelRemains;
  if (!Array.isArray(rows)) throw new Error('parse');
  const windows = [], seen = new Set();
  for (const row of rows) {
    const model = String(field(row, 'model_name') ?? '').trim();
    if (!model) continue;
    const pool = model === 'general' || model === 'MiniMax-M*' ? 'M-series' : model;
    for (const weekly of [false, true]) {
      const prefix = weekly ? 'current_weekly' : 'current_interval';
      const status = num(field(row, `${prefix}_status`));
      if (status === 3) continue;
      const total = num(field(row, `${prefix}_total_count`)), count = num(field(row, `${prefix}_usage_count`));
      let remaining = num(field(row, `${prefix}_remaining_percent`));
      let used = total > 0 && count != null && count >= 0 && count <= total ? (endpoint === 'coding_plan' ? total - count : count) : null;
      // Counts have varied in the wild. Keep them only when they agree with the authoritative percentage.
      if (remaining != null && used != null && Math.abs((total - used) / total * 100 - remaining) > 1) used = null;
      if (status === 2) { remaining = 0; if (total > 0) used = total; }
      if (remaining == null && used == null) continue;
      const start = resetSeconds(field(row, weekly ? 'weekly_start_time' : 'start_time'));
      const end = resetSeconds(field(row, weekly ? 'weekly_end_time' : 'end_time'));
      const span = start != null && end > start ? end - start : null;
      const period = weekly ? '7d' : span != null ? (span % 3600 === 0 ? `${span / 3600}h` : `${span}s`) : 'unknown';
      const id = `${pool}:${weekly}`;
      if (seen.has(id)) continue;
      seen.add(id);
      const unit = model.toLowerCase() === 'video' ? 'videos' : model.toLowerCase() === 'image' ? 'images' : 'count';
      windows.push(window(`${pool} · ${period}`, period, used, used != null ? total : null, end, unit,
        remaining != null ? 100 - pct(remaining) : null));
    }
  }
  return output(windows, undefined, windows.filter(w => w.label.startsWith('M-series · ')));
}
export function parseKimi(body) {
  let windows = [];
  for (const row of body?.limits ?? []) {
    const duration = num(row.window?.duration), unit = String(row.window?.timeUnit ?? '').toUpperCase();
    const multiplier = unit.includes('MINUTE') ? 60 : unit.includes('HOUR') ? 3600 : unit.includes('DAY') ? 86400 : unit.includes('WEEK') ? 604800 : unit.includes('MONTH') ? 2592000 : unit.includes('SECOND') ? 1 : null;
    const seconds = duration != null && multiplier != null ? duration * multiplier : null;
    const period = seconds === 18000 ? '5h' : seconds === 604800 ? '7d' : seconds === 2592000 ? 'month' : seconds > 0 ? `${seconds}s` : 'unknown';
    const w = counted(row.detail ?? row.window, period, period);
    if (w) windows.push(w);
  }
  const replacePeriod = (period, w) => { windows = windows.filter(x => x.period !== period); windows.push(w); };
  const weekly = counted(body?.usage, '7d', '7d');
  if (weekly) replacePeriod('7d', weekly);
  for (const [key, period] of [['limit_5h', '5h'], ['limit_7d', '7d'], ['limit_month_total', 'month'], ['limit_month_code', 'month']]) {
    const row = field(body?.usages, key), ratio = num(field(row, 'used_ratio'));
    if (ratio == null) continue;
    if (key === 'limit_month_code' && num(field(field(body?.usages, 'limit_month_total'), 'used_ratio')) != null) continue;
    replacePeriod(period, window(period, period, null, null, resetOf(row), 'count', ratio * 100));
  }
  const rank = { '5h': 1, '7d': 2, month: 3 };
  return output(windows.sort((a, b) => (rank[a.period] ?? 4) - (rank[b.period] ?? 4)), body?.user?.membership?.level);
}
export function parseCodeBuddy(body) {
  if (num(body?.code) !== 0) throw new Error('api');
  const accounts = body?.data?.Response?.Data?.Accounts;
  if (!Array.isArray(accounts)) throw new Error('parse');
  const windows = accounts.map((a, index) => {
    const start = resetSeconds(a.CycleStartTime), end = resetSeconds(a.CycleEndTime), expiry = resetSeconds(a.DeductionEndTime);
    const recurring = end != null && expiry != null && expiry - end > 172800;
    const days = start != null && end > start ? (end - start) / 86400 : null;
    const period = recurring ? days == null ? 'unknown' : days <= 1.5 ? '1d' : days <= 10 ? '7d' : days <= 32 ? 'month' : `${days}d` : 'expiry';
    const prefix = recurring ? 'CycleCapacity' : 'Capacity';
    const used = num(a[`${prefix}UsedPrecise`]) ?? num(a[`${prefix}Used`]);
    const total = num(a[`${prefix}SizePrecise`]) ?? num(a[`${prefix}Size`]);
    return window(`${recurring ? '周期额度' : '赠送额度（到期）'} ${index + 1}`, period, used, total, end, 'credits');
  }).filter(w => w.amount != null || w.limit != null);
  return output(windows, accounts[0]?.PackageName ?? accounts[0]?.SubProductName);
}
export function parseCommandCode(body, subscription = {}) {
  if (body?.success === false) throw new Error('api');
  const windows = [];
  for (const [name, period] of [['fiveHour', '5h'], ['weekly', '7d']]) {
    const row = body?.windowLimits?.[name];
    if (!row) continue;
    const used = num(row.used), cap = num(row.cap);
    if (used == null && cap == null) continue;
    windows.push(window(period, period, used, cap, resetSeconds(row.resetAt), 'credits'));
  }
  const credits = body?.credits;
  const monthly = num(credits?.monthlyCredits);
  const end = subscription?.success === false ? null : resetSeconds(subscription?.data?.currentPeriodEnd);
  // Balance rows carry remaining amount, with no limit or percentage. The explicit
  // balance period and label distinguish these from counted used/limit windows.
  if (monthly != null) windows.push({ label: '月剩余余额', amount: monthly, period: 'balance', unit: 'credits', resets_at: end });
  for (const [key, label] of [['purchasedCredits', '购买余额'], ['freeCredits', '免费余额']]) {
    const balance = num(credits?.[key]);
    if (balance != null) windows.push({ label: `${label}（剩余）`, amount: balance, period: 'balance', unit: 'credits', resets_at: null });
  }
  return output(windows, subscription?.data?.planId ?? credits?.planId);
}

const buddyHeaders = mode => ({ 'User-Agent': `${mode}/2.108.1 CodeBuddy/2.108.1`, 'X-Product': 'SaaS', 'X-IDE-Type': mode, 'X-IDE-Name': mode, 'x-requested-with': 'XMLHttpRequest', 'x-codebuddy-request': '1' });
export const codingProviders = {
  'zai-coding': { url: 'https://api.z.ai/api/monitor/usage/quota/limit', bare: true, parse: parseZai },
  'minimax-coding-cn': { url: 'https://api.minimaxi.com/v1/token_plan/remains', parse: parseMiniMax },
  'minimax-coding': { url: 'https://api.minimax.io/v1/token_plan/remains', parse: parseMiniMax },
  'kimi-code-cn': { url: 'https://api.kimi.com/coding/v1/usages', parse: parseKimi },
  'kimi-code': { url: 'https://api.kimi.ai/coding/v1/usages', parse: parseKimi },
  'codebuddy-cn': { url: 'https://copilot.tencent.com/v2/billing/meter/get-user-resource', method: 'POST', headers: buddyHeaders('CLI'), parse: parseCodeBuddy },
  codebuddy: { url: 'https://www.codebuddy.ai/v2/billing/meter/get-user-resource', method: 'POST', headers: buddyHeaders('IDE'), parse: parseCodeBuddy },
  commandcode: { url: 'https://api.commandcode.ai/alpha/billing/credits', parse: parseCommandCode },
};
function readJSON(path) { try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; } }
function request(config, key, deadline) {
  const seconds = Math.min(8, (deadline - Date.now()) / 1000);
  if (seconds <= 0) throw new Error('network');
  const headers = { Accept: 'application/json', Authorization: `${config.bare ? '' : 'Bearer '}${key}`, ...config.headers };
  if (config.method === 'POST') headers['Content-Type'] = 'application/json';
  const r = spawnSync(process.env.TOKENHUD_CURL || '/usr/bin/curl', [
    '-q', '-sS', '--connect-timeout', String(Math.min(3, seconds)), '--max-time', String(seconds), '--proto', '=https',
    ...Object.entries(headers).flatMap(([k, v]) => ['-H', `${k}: ${v}`]),
    ...(config.method === 'POST' ? ['-X', 'POST', '--data', '{}'] : []),
    '-w', '\n%{http_code}', '--url', config.url,
  ], { encoding: 'utf8', timeout: Math.ceil(seconds * 1000) + 200, killSignal: 'SIGKILL', maxBuffer: 2_000_000, stdio: ['ignore', 'pipe', 'pipe'] });
  if (r.error || r.status !== 0) throw new Error('network');
  const split = r.stdout.lastIndexOf('\n'), code = Number(r.stdout.slice(split + 1).trim());
  if (code === 401 || code === 403) throw new Error('auth');
  if (code === 429) throw new Error('ratelimit');
  if (code < 200 || code >= 300 || !Number.isInteger(code)) throw new Error('network');
  try { return JSON.parse(r.stdout.slice(0, split)); } catch { throw new Error('parse'); }
}
export function main() {
  const id = process.env.TOKENHUD_CODING_PROVIDER;
  const config = codingProviders[id];
  const hud = process.env.TOKENHUD_HUD_DIR || join(homedir(), '.claude', 'hud');
  const cache = process.env.TOKENHUD_CACHE_FILE || join(hud, `.${id}-usage-cache.json`);
  let result;
  try {
    if (!config) throw new Error('unsupported-provider');
    // Only the explicitly selected query snapshot is accepted; no legacy credentials or CLI discovery.
    const auth = process.env.TOKENHUD_AUTH_FILE ? readJSON(process.env.TOKENHUD_AUTH_FILE) : null;
    const key = typeof auth?.queryKey === 'string' ? auth.queryKey.trim() : '';
    if (!key || /[\r\n\x00]/.test(key)) throw new Error('no-auth');
    const deadline = Date.now() + 18000;
    const body = request(config, key, deadline);
    let subscription = {};
    if (id === 'commandcode') {
      try { subscription = request({ url: 'https://api.commandcode.ai/alpha/billing/subscriptions' }, key, deadline); }
      catch { /* Real window data remains useful when the optional month-end lookup fails. */ }
    }
    const usage = config.parse(body, id === 'commandcode' ? subscription : undefined);
    if (!usage.windows.length) throw new Error('unknown');
    result = { ...usage, generatedAt: Date.now(), ttlMs: 60000, error: null, stale: false };
  } catch (error) {
    result = { error: error.message, lastAttemptAt: Date.now(), ttlMs: 60000, stale: true };
  }
  if (process.env.TOKENHUD_STDOUT_ONLY === '1') process.stdout.write(JSON.stringify(result) + '\n');
  else { mkdirSync(dirname(cache), { recursive: true }); writeFileSync(cache, JSON.stringify(result, null, 2)); }
}
if (process.argv[1] && realpathSync(resolve(process.argv[1])) === fileURLToPath(import.meta.url)) main();
