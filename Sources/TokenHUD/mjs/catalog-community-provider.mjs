#!/usr/bin/env node
// Independently implemented from endpoint/field facts at community plugins
// 3e24e228377ed17a9e5991c4e715dfde0244a1ea; no upstream implementation copied.
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

export const communityProviders = Object.freeze({
  factory: { url: 'https://api.factory.ai/api/billing/limits', modes: ['apikey'], headers: { 'X-Factory-Client': 'cli', 'X-Client-Version': '0.242.0', 'User-Agent': 'factory-cli/0.242.0' } },
  'agnes-code': { url: 'https://api.agnes-ai.com/api/v2/subscription/credits-balance', modes: ['apikey', 'auth'] },
  catpaw: { url: 'https://catx.nocode.cn/api/gateway/credit/balance', modes: ['auth'], headers: { 'gray-set': 'new-agent-sdk' } },
  loomy: { url: 'https://loomyad.xunfei.cn/api/v2/points/records?pageNo=1&pageSize=1&direction=debit&granularity=chat', modes: ['auth'] },
});
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const number = value => {
  if (!['number', 'string'].includes(typeof value) || (typeof value === 'string' && !value.trim())) return null;
  const n = Number(value);
  return Number.isFinite(n) && n >= 0 ? n : null;
};
const clean = value => typeof value === 'string' && !/[\r\n\0]/.test(value) ? value.trim() : '';
const balance = (label, amount, unit = 'credits') => ({ label, amount, unit, period: 'balance' });
const reset = value => {
  const milliseconds = typeof value === 'number' || /^\d+$/.test(String(value)) ? Number(value) : (typeof value === 'string' && /^\d{4}-\d\d-\d\dT.*(?:Z|[+-]\d\d:\d\d)$/.test(value) ? Date.parse(value) : NaN);
  return Number.isFinite(milliseconds) && milliseconds > 0 ? Math.floor(milliseconds / 1000) : null;
};
export function parseCommunityUsage(provider, data) {
  if (!object(data)) return null;
  const windows = [];
  if (provider === 'factory') {
    for (const [pool, prefix] of [['standard', 'Standard'], ['core', 'Droid Core']]) {
      for (const [key, label, period] of [['fiveHour', '5h', '5h'], ['weekly', '7d', '7d'], ['monthly', '30d', 'monthly']]) {
        const meter = data.limits?.[pool]?.[key];
        const used = number(meter?.usedPercent);
        if (used === null || used > 100) continue;
        const window = { label: `${prefix} ${label}`, used_percentage: used, period };
        const at = reset(meter.windowEnd);
        if (at !== null) window.resets_at = at;
        windows.push(window);
      }
    }
    const cents = number(data.extraUsageBalanceCents);
    if (cents !== null) windows.push(balance('额外用量余额', cents / 100, 'USD'));
  } else if (provider === 'agnes-code') {
    if (data.success === false || (data.code !== undefined && String(data.code) !== '000000')) return null;
    const values = data.data;
    if (!object(values)) return null;
    for (const [key, label] of [['total_balance', '积分余额'], ['time_sensitive_balance', '限时积分余额'], ['permanent_balance', '永久积分余额']]) {
      const n = number(values[key]);
      if (n !== null) windows.push(balance(label, n));
    }
  } else if (provider === 'catpaw') {
    if (data.code !== 0 || !object(data.data)) return null;
    const n = number(data.data.availableCredits ?? data.data.credit ?? data.data.balance ?? data.data.available);
    if (n !== null) windows.push(balance('可用积分余额', n));
  } else if (provider === 'loomy') {
    if (String(data.code) !== '000000') return null;
    const values = data.data?.data ?? data.data;
    if (!object(values)) return null;
    // Remaining points are balances, not percentages or a promised reset.
    const daily = number(values.dailyRemainingPoints) ?? number(values.dailyBalance);
    const permanent = number(values.balance);
    if (daily !== null) windows.push(balance('每日赠送积分余额', daily));
    if (permanent !== null) windows.push(balance('永久积分余额', permanent));
  }
  return windows.length ? { windows } : null;
}
const readJSON = path => { try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; } };
export function main() {
  const provider = process.env.USAGE_PROVIDER_NAME;
  const config = communityProviders[provider];
  const hud = process.env.TOKENHUD_HUD_DIR || join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'hud');
  const authFile = process.env.TOKENHUD_AUTH_FILE || process.env.USAGE_AUTH_FILE;
  const cacheFile = process.env.TOKENHUD_CACHE_FILE || process.env.USAGE_CACHE_FILE || join(hud, `.${provider}-usage-cache.json`);
  const emit = output => {
    if (process.env.TOKENHUD_STDOUT_ONLY === '1') process.stdout.write(JSON.stringify(output) + '\n');
    else { mkdirSync(dirname(cacheFile), { recursive: true }); writeFileSync(cacheFile, JSON.stringify(output, null, 2)); }
  };
  const fail = (error, message) => emit({ error, ...(message ? { message } : {}), stale: true, lastAttemptAt: Date.now(), ttlMs: 60_000 });
  if (!config) { fail('no-query'); return; }
  const snapshot = authFile ? readJSON(authFile) : null;
  if (!config.modes.includes(snapshot?.authMode)) { fail('no-auth', '请选择此类型支持的基础认证方式。'); return; }
  const key = clean(snapshot.queryKey);
  if (!key) { fail('no-auth', '缺少基础认证；请更新原客户端授权或选择有效导出文件。'); return; }
  const headers = { Accept: 'application/json', ...config.headers };
  if (provider === 'catpaw') headers['X-Auth-Token'] = key;
  else {
    headers.Authorization = `Bearer ${key}`;
    if (provider === 'loomy') headers.token = key;
  }
  const args = ['-q', '-sS', '--connect-timeout', '3', '--max-time', '12', '--proto', '=https', '-X', 'GET'];
  for (const [name, value] of Object.entries(headers)) args.push('-H', `${name}: ${value}`);
  args.push('-w', '\n%{http_code}', '--url', config.url);
  const response = spawnSync(process.env.TOKENHUD_CURL || '/usr/bin/curl', args, { encoding: 'utf8', timeout: 13_000, killSignal: 'SIGKILL', maxBuffer: 2_000_000, stdio: ['ignore', 'pipe', 'pipe'] });
  if (response.error || response.status !== 0) { fail('network'); return; }
  const cut = response.stdout.lastIndexOf('\n');
  const status = cut < 0 ? NaN : Number(response.stdout.slice(cut + 1).trim());
  if (status === 401 || status === 403 || (status >= 300 && status < 400)) { fail('auth'); return; }
  if (status === 429) { fail('ratelimit'); return; }
  if (status !== 200) { fail('network'); return; }
  let data;
  try { data = JSON.parse(response.stdout.slice(0, cut)); } catch { fail('parse'); return; }
  if ((provider === 'catpaw' && [4010, 4011].includes(data?.code)) || (provider === 'loomy' && ['020002', '100002'].includes(String(data?.code)))) { fail('auth'); return; }
  const usage = parseCommunityUsage(provider, data);
  if (!usage) { fail('parse', '服务端未返回可识别额度，当前用量未知。'); return; }
  emit({ ...usage, generatedAt: Date.now(), ttlMs: 60_000, error: null, stale: false });
}
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main();
