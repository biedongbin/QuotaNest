#!/usr/bin/env node
// Protocol facts: magpie-community/plugins 3e24e228377ed17a9e5991c4e715dfde0244a1ea,
// packages/{zcode,joycode,raccoon,autoclaw}/index.mjs. Independently written;
// only public client signature constants are retained, no upstream implementation copied.
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash, createHmac, randomBytes } from 'node:crypto';
const JOY_SIGN_KEY = '0691a3f0b37b4a85aeb63ad0fc7db3ed';
const AUTO_APP_KEY = '38d2391985e2369a5fb8227d8e6cd5e5';
export const workspaceProviders = Object.freeze({
  'zcode-start': 'https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=3.17.2',
  joycode: 'https://api-ai.jd.com/api',
  raccoon: 'https://xiaohuanxiong.com/api/web/points/v1/balance',
  'autoclaw-cn': 'https://autoglm-api.zhipuai.cn/agent-assetmgr/api/v2/wallets?biz_app_id=autoclaw',
  autoclaw: 'https://autoglm-api.autoglm.ai/agent-assetmgr/api/v2/wallets?biz_app_id=autoclaw',
});
const obj = x => x !== null && typeof x === 'object' && !Array.isArray(x);
const num = x => (typeof x === 'number' || typeof x === 'string' && x.trim()) && Number.isFinite(Number(x)) && Number(x) >= 0 ? Number(x) : null;
const text = x => typeof x === 'string' && !/[\r\n\0]/.test(x) ? x.trim() : '';
const balance = (label, amount, unit = 'credits') => ({ label: `${label}余额`, amount, unit, period: 'balance' });
const json = path => { try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; } };
export function parseWorkspaceUsage(provider, data, now = Date.now()) {
  if (!obj(data)) return null;
  const windows = [];
  if (provider === 'zcode-start') {
    const clock = num(data.server_time) ?? now / 1000;
    const live = (Array.isArray(data.plans) ? data.plans : []).filter(p => p.status === 'active' && !(num(p.starts_at) > clock) && !(num(p.ends_at) > 0 && num(p.ends_at) <= clock));
    for (const b of Array.isArray(data.balances) ? data.balances : []) {
      const owner = live.find(p => b.user_plan_id && p.user_plan_id ? b.user_plan_id === p.user_plan_id : b.plan_id && b.plan_id === p.plan_id);
      if (!owner || num(b.expires_at) > 0 && num(b.expires_at) <= clock) continue;
      const left = num(b.remaining_units), total = num(b.total_units), used = num(b.used_units);
      const remaining = left ?? (total !== null && used !== null && total >= used ? total - used : null);
      if (remaining === null) continue;
      // Expiry is not a reset; no synthetic recurring window or pool sum.
      windows.push(balance(text(b.show_name) || text(owner.name) || 'Gift', remaining));
    }
  } else if (provider === 'joycode') {
    for (const row of Array.isArray(data.usageItems) ? data.usageItems : []) {
      const left = num(row?.remain);
      if (left !== null) windows.push(balance(text(row.title) || '积分', left, text(row.unit) || '积分'));
    }
  } else if (provider === 'raccoon') {
    const n = num(data.available_points);
    if (n !== null) windows.push(balance('积分', n));
  } else if (provider === 'autoclaw' || provider === 'autoclaw-cn') {
    const total = num(data.total_balance);
    if (total === null) return null;
    windows.push(balance('总积分', total));
    for (const row of Array.isArray(data.wallets) ? data.wallets : []) {
      const n = num(row?.balance);
      if (row?.display !== false && n !== null) windows.push(balance(text(row.display_name) || text(row.public_wallet_type) || '分池积分', n));
    }
  }
  return windows.length ? { windows } : null;
}
export function buildWorkspaceRequest(provider, key, context = {}, now = Date.now()) {
  let url = workspaceProviders[provider];
  if (!url) throw new Error('no-query');
  const headers = { Accept: 'application/json', Authorization: `Bearer ${key}` };
  let method = 'GET', body;
  if (provider === 'zcode-start') {
    const device = text(context.device);
    if (!device) throw new Error('no-context');
    Object.assign(headers, { 'X-Device-Mid': device, 'Content-Type': 'application/json', 'User-Agent': 'ZCode/3.17.2' });
  } else if (provider === 'joycode') {
    const fields = { appid: 'joycode_ide', functionId: 'get_newpoint_ide', t: String(now) };
    const material = Object.keys(fields).sort().map(k => fields[k]).join('&');
    const sign = createHmac('sha256', JOY_SIGN_KEY).update(material).digest('hex');
    url += '?' + new URLSearchParams({ ...fields, sign });
    delete headers.Authorization;
    headers.ptkey = key;
    headers.logintype = text(context.loginType) || 'PIN_JD_CLOUD';
    if (text(context.tenant)) headers.tenant = encodeURIComponent(context.tenant);
    headers['content-type'] = 'application/json; charset=UTF-8';
    method = 'POST'; body = '{}';
  } else if (provider.startsWith('autoclaw')) {
    const ts = String(Math.floor(now / 1000));
    const platform = process.platform === 'darwin' ? 'mac' : process.platform === 'win32' ? 'win' : process.platform;
    Object.assign(headers, { Accept: '*/*', 'Content-Type': 'application/json', 'User-Agent': `AutoClaw/1.18.1 (${platform}-${process.arch})`, 'X-Version': '1.18.1', 'X-Tm': platform, 'X-Product': 'autoclaw', 'X-Auth-Appid': '100003', 'X-Auth-TimeStamp': ts, 'X-Auth-Sign': createHash('md5').update(`100003&${ts}&${AUTO_APP_KEY}`).digest('hex'), 'X-Trace-Id': randomBytes(16).toString('hex'), 'X-Lang': 'zh-CN', 'X-Channel': 'AutoClaw4', Origin: 'http://localhost:18432', Referer: 'http://localhost:18432/' });
  }
  return { url, headers, method, body };
}
export function main() {
  const provider = process.env.USAGE_PROVIDER_NAME;
  const authFile = process.env.TOKENHUD_AUTH_FILE || process.env.USAGE_AUTH_FILE;
  const cacheFile = process.env.TOKENHUD_CACHE_FILE || process.env.USAGE_CACHE_FILE;
  const emit = value => {
    if (process.env.TOKENHUD_STDOUT_ONLY === '1') process.stdout.write(JSON.stringify(value) + '\n');
    else if (cacheFile) { mkdirSync(dirname(cacheFile), { recursive: true }); writeFileSync(cacheFile, JSON.stringify(value)); }
  };
  const fail = error => emit({ error, stale: true, lastAttemptAt: Date.now(), ttlMs: 60000 });
  const snapshot = authFile ? json(authFile) : null;
  if (!workspaceProviders[provider]) return fail('no-query');
  if (snapshot?.authMode !== 'auth') return fail('no-auth');
  const rawKey = text(snapshot.queryKey);
  const key = provider === 'joycode' ? rawKey : rawKey.replace(/^Bearer\s+/i, '').trim();
  if (!key) return fail('no-auth');
  const context = obj(snapshot.tokenhudAuthContext) ? snapshot.tokenhudAuthContext : {};
  // Expired sessions are renewed by the source owner, never by this reader.
  const exp = num(context.expiresAt);
  if (exp > 0 && (exp >= 1e12 ? exp : exp * 1000) <= Date.now()) return fail('auth');
  try {
    const claims = JSON.parse(Buffer.from(key.split('.')[1] || '', 'base64url').toString());
    if (num(claims.exp) > 0 && Number(claims.exp) * 1000 <= Date.now()) return fail('auth');
  } catch { /* Opaque credentials are supported. */ }
  let request;
  try { request = buildWorkspaceRequest(provider, key, context); } catch (e) { return fail(e.message); }
  const args = ['-q', '-sS', '--connect-timeout', '3', '--max-time', '12', '--proto', '=https', '-X', request.method];
  for (const [name, value] of Object.entries(request.headers)) args.push('-H', `${name}: ${value}`);
  if (request.body !== undefined) args.push('--data-binary', request.body);
  args.push('-w', '\n%{http_code}', '--url', request.url);
  const result = spawnSync(process.env.TOKENHUD_CURL || '/usr/bin/curl', args, { encoding: 'utf8', timeout: 13000, maxBuffer: 2000000, killSignal: 'SIGKILL', stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.error || result.status !== 0) return fail('network');
  const cut = result.stdout.lastIndexOf('\n'), status = Number(result.stdout.slice(cut + 1));
  if (status === 401 || status === 403 || status >= 300 && status < 400) return fail('auth');
  if (status === 429) return fail('ratelimit');
  if (status !== 200) return fail('network');
  let envelope;
  try { envelope = JSON.parse(result.stdout.slice(0, cut)); } catch { return fail('parse'); }
  if (!obj(envelope)) return fail('parse');
  if ([401, 200001, 200003].includes(Number(envelope.code))) return fail('auth');
  if (envelope.code !== undefined && !['0', '200'].includes(String(envelope.code))) return fail('parse');
  const usage = parseWorkspaceUsage(provider, envelope.data ?? envelope);
  if (!usage) return fail('parse');
  emit({ ...usage, generatedAt: Date.now(), ttlMs: 60000, error: null, stale: false });
}
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main();
