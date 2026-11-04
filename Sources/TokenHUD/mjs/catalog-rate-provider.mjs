#!/usr/bin/env node
// API facts: 9router services/usage/{opencode-zen,shared}.js and registry.
// Zen's literal URL below is extracted statically from registry, never guessed.
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
export const rateProviders = Object.freeze({
  'opencode-zen': { url: "https://opencode.ai/zen/v1/usage" },
});
const number = value => {
  if (!['string', 'number'].includes(typeof value) || (typeof value === 'string' && !value.trim())) return null;
  const result = Number(value);
  return Number.isFinite(result) ? result : null;
};
export function epochSeconds(value) {
  const numeric = number(value);
  if (numeric !== null) return numeric > 0 ? Math.floor(numeric >= 1e12 ? numeric / 1000 : numeric) : null;
  const parsed = typeof value === 'string' ? Date.parse(value) : NaN;
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed / 1000) : null;
}
export function parseZen(data) {
  if (!data?.usage || typeof data.usage !== 'object' || Array.isArray(data.usage)) return null;
  const windows = [];
  for (const [period, label] of [['rolling', '滚动窗口'], ['weekly', '每周'], ['monthly', '每月']]) {
    const quota = data.usage[period];
    const percent = number(quota?.percent);
    if (percent === null || percent < 0) continue;
    windows.push({ label, period, used_percentage: percent, resets_at: epochSeconds(quota.resetsAt) });
  }
  return windows.length ? { windows } : null;
}
// curl -D - may include a CONNECT/100 header block before the final response.
export function splitResponse(text) {
  let body = text;
  let headers = {};
  while (/^HTTP\/\S+\s+\d{3}[^\r\n]*\r?\n/.test(body)) {
    const end = /\r?\n\r?\n/.exec(body);
    if (!end) break;
    headers = {};
    for (const line of body.slice(0, end.index).split(/\r?\n/).slice(1)) {
      const separator = line.indexOf(':');
      if (separator > 0) headers[line.slice(0, separator).trim().toLowerCase()] = line.slice(separator + 1).trim();
    }
    body = body.slice(end.index + end[0].length);
  }
  return { headers, body };
}
const readJSON = path => { try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; } };
export function main() {
  const provider = process.env.USAGE_PROVIDER_NAME;
  const config = Object.hasOwn(rateProviders, provider) ? rateProviders[provider] : null;
  const hud = process.env.TOKENHUD_HUD_DIR || join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'hud');
  const authFile = process.env.TOKENHUD_AUTH_FILE || process.env.USAGE_AUTH_FILE;
  const cacheFile = process.env.TOKENHUD_CACHE_FILE || process.env.USAGE_CACHE_FILE || join(hud, `.${provider}-usage-cache.json`);
  const emit = value => {
    if (process.env.TOKENHUD_STDOUT_ONLY === '1') process.stdout.write(JSON.stringify(value) + '\n');
    else { mkdirSync(dirname(cacheFile), { recursive: true }); writeFileSync(cacheFile, JSON.stringify(value, null, 2)); }
  };
  // The native engine retains last-good values only after checking the account source.
  const fail = (error, message) => emit({ error,
    ...(message ? { message } : {}), stale: true, lastAttemptAt: Date.now(), ttlMs: 60_000 });
  if (!config) { fail('no-query', '此类型的额度未知。'); return; }
  const snapshot = authFile ? readJSON(authFile) : null;
  const key = typeof snapshot?.queryKey === 'string' ? snapshot.queryKey.trim() : '';
  if (!key || /[\r\n\0]/.test(key)) { fail('no-auth'); return; }
  const result = spawnSync(process.env.TOKENHUD_CURL || '/usr/bin/curl', [
    '-q', '-sS', '--connect-timeout', '3', '--max-time', '12', '--proto', '=https',
    '-H', `Authorization: Bearer ${key}`, '-H', 'Accept: application/json',
    '-H', 'User-Agent: TokenHUD/1.0', '-D', '-', '-w', '\n%{http_code}', '--url', config.url,
  ], { encoding: 'utf8', timeout: 13_000, killSignal: 'SIGKILL', maxBuffer: 2_000_000, stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.error || result.status !== 0) { fail('network'); return; }
  const separator = result.stdout.lastIndexOf('\n');
  const status = Number(result.stdout.slice(separator + 1).trim());
  const response = splitResponse(result.stdout.slice(0, separator));
  if (provider === 'opencode-zen' && status === 403) {
    let error;
    try { error = JSON.parse(response.body)?.error; } catch { /* Non-JSON denial remains auth. */ }
    if (error?.type === 'EntitlementError') { fail('no-query', '此 Key 未提供 OpenCode Zen 套餐窗口，额度未知。'); return; }
  }
  if ([401, 403, 301, 302, 303, 307, 308].includes(status)) { fail('auth'); return; }
  if (status === 429) { fail('ratelimit'); return; }
  if (status !== 200) { fail('network'); return; }
  let data;
  try { data = JSON.parse(response.body); } catch { fail('parse'); return; }
  const usage = parseZen(data);
  if (!usage) {
    fail('no-query', '响应未提供 OpenCode Zen 套餐窗口，额度未知。');
    return;
  }
  emit({ ...usage, generatedAt: Date.now(), ttlMs: 60_000, error: null, stale: false });
}
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main();
