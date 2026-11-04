#!/usr/bin/env node
// API facts verified against Magpie balance.go/presets.go and 9router usage/misc.js.
// The account query snapshot is the sole credential source; no external Auth discovery.
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

export const balanceProviders = Object.freeze({
  deepseek: { url: 'https://api.deepseek.com/user/balance' },
  'moonshot-cn': { url: 'https://api.moonshot.cn/v1/users/me/balance', unit: 'CNY' },
  moonshot: { url: 'https://api.moonshot.ai/v1/users/me/balance', unit: 'USD' },
  openrouter: { url: 'https://openrouter.ai/api/v1/credits', unit: 'USD' },
  aihubmix: { url: 'https://aihubmix.com/dashboard/billing/remain', unit: 'USD' },
  'stepfun-cn': { url: 'https://api.stepfun.com/v1/accounts', unit: 'CNY' },
  stepfun: { url: 'https://api.stepfun.ai/v1/accounts', unit: 'USD' },
  'vercel-ai-gateway': { url: 'https://ai-gateway.vercel.sh/v1/credits', unit: 'USD' },
});
const numeric = value => {
  if (typeof value !== 'number' && typeof value !== 'string') return null;
  if (typeof value === 'string' && !value.trim()) return null;
  const result = Number(value);
  return Number.isFinite(result) ? result : null;
};
const balanceWindow = (amount, unit) => ({ label: '余额', amount, unit, period: 'balance' });
export function parseBalance(provider, data) {
  const config = balanceProviders[provider];
  if (!config || !data || typeof data !== 'object' || Array.isArray(data)) return null;
  if (provider === 'deepseek') {
    if (!Array.isArray(data.balance_infos)) return null;
    const windows = data.balance_infos.flatMap(info => {
      const amount = numeric(info?.total_balance);
      const unit = typeof info?.currency === 'string' ? info.currency.trim().toUpperCase() : '';
      return amount !== null && /^[A-Z]{3}$/.test(unit) ? [balanceWindow(amount, unit)] : [];
    });
    return windows.length ? { windows } : null;
  }
  let amount;
  if (provider === 'openrouter') {
    const credits = numeric(data.data?.total_credits);
    const usage = numeric(data.data?.total_usage);
    if (credits === null || usage === null) return null;
    amount = credits - usage;
  } else if (provider === 'moonshot' || provider === 'moonshot-cn') {
    if (data.status === false || (data.code != null && data.code !== 0)) return null;
    amount = numeric(data.data?.available_balance);
  } else if (provider === 'aihubmix') {
    amount = numeric(data.total_usage);
    if (amount !== null && amount < 0) return { error: 'no-query', message: '此 AiHubmix Key 无限额，接口不提供账户余额。' };
  } else {
    amount = numeric(data.balance);
  }
  return amount !== null && Number.isFinite(amount) ? { windows: [balanceWindow(amount, config.unit)] } : null;
}
const readJSON = path => { try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; } };
export function main() {
  const provider = process.env.USAGE_PROVIDER_NAME;
  const config = balanceProviders[provider];
  const hud = process.env.TOKENHUD_HUD_DIR || join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'hud');
  const authFile = process.env.TOKENHUD_AUTH_FILE || process.env.USAGE_AUTH_FILE;
  const cacheFile = process.env.TOKENHUD_CACHE_FILE || process.env.USAGE_CACHE_FILE || join(hud, `.${provider}-usage-cache.json`);
  const emit = value => {
    if (process.env.TOKENHUD_STDOUT_ONLY === '1') process.stdout.write(JSON.stringify(value) + '\n');
    else { mkdirSync(dirname(cacheFile), { recursive: true }); writeFileSync(cacheFile, JSON.stringify(value, null, 2)); }
  };
  const fail = (error, message) => emit({ error, ...(message ? { message } : {}), stale: true, lastAttemptAt: Date.now(), ttlMs: 60_000 });
  if (!config) { fail('no-query'); return; }
  const snapshot = authFile ? readJSON(authFile) : null;
  const key = typeof snapshot?.queryKey === 'string' ? snapshot.queryKey.trim() : '';
  if (!key || /[\r\n\0]/.test(key)) { fail('no-auth'); return; }
  const result = spawnSync(process.env.TOKENHUD_CURL || '/usr/bin/curl', [
    '-q', '-sS', '--connect-timeout', '3', '--max-time', '12', '--proto', '=https',
    '-H', `Authorization: Bearer ${key}`, '-H', 'Accept: application/json',
    '-w', '\n%{http_code}', '--url', config.url,
  ], { encoding: 'utf8', timeout: 13_000, killSignal: 'SIGKILL', maxBuffer: 2_000_000, stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.error || result.status !== 0) { fail('network'); return; }
  const separator = result.stdout.lastIndexOf('\n');
  const status = Number(result.stdout.slice(separator + 1).trim());
  if ([401, 403, 301, 302, 303, 307, 308].includes(status)) { fail('auth'); return; }
  if (status === 429) { fail('ratelimit'); return; }
  if (status !== 200) { fail('network'); return; }
  let data;
  try { data = JSON.parse(result.stdout.slice(0, separator)); } catch { fail('parse'); return; }
  const usage = parseBalance(provider, data);
  if (!usage || usage.error) { fail(usage?.error || 'parse', usage?.message); return; }
  emit({ ...usage, generatedAt: Date.now(), ttlMs: 60_000, error: null, stale: false });
}
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main();
