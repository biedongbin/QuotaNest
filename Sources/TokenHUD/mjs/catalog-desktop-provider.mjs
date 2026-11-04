#!/usr/bin/env node
// Wire contracts adapted from magpie-community/plugins @ 3e24e228377ed17a9e5991c4e715dfde0244a1ea.
// Copyright (c) 2026 magpie-community contributors. MIT License:
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
// Read only the selected core snapshot. No external discovery, renewal, or login.
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

export const desktopProviders = Object.freeze({
  cursor: { host: 'https://api2.cursor.sh', path: '/aiserver.v1.DashboardService/GetCurrentPeriodUsage' },
  'workbuddy-cn': { host: 'https://copilot.tencent.com', path: '/billing/meter/get-user-resource-summary' },
  workbuddy: { host: 'https://www.workbuddy.ai', path: '/billing/meter/get-user-resource-summary' },
  'xiaomi-mimo-desktop': { host: 'https://mimo-server-sgp.xiaomimimo.com', path: '/api/user/usage' },
  'trae-cn': { host: 'https://api.trae.cn', path: '/trae/api/v2/pay/ide_user_ent_usage' },
  trae: { host: 'https://api-sg-central.trae.ai', path: '/trae/api/v1/pay/user_current_entitlement_list' },
});
const record = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const num = v => (typeof v === 'number' || typeof v === 'string' && v.trim()) && Number.isFinite(Number(v)) ? Number(v) : null;
const clean = v => typeof v === 'string' && !/[\x00-\x1f\x7f]/.test(v) ? v.trim() : '';
const pct = n => Math.max(0, Math.min(100, n));
const parseJSON = text => { try { return JSON.parse(text); } catch { return null; } };
const readJSON = path => { try { return parseJSON(readFileSync(path, 'utf8')); } catch { return null; } };
export function instant(v, localOffset) {
  const n = num(v);
  if (n !== null) return n > 0 ? n >= 1e12 ? n / 1000 : n : null;
  if (typeof v !== 'string') return null;
  if (localOffset && /^\d{4}-\d\d-\d\d$/.test(v)) return instant(v + 'T00:00:00' + localOffset);
  if (!/^\d{4}-\d\d-\d\d[T ]/.test(v)) return null;
  const text = /^\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(?:\.\d+)?$/.test(v)
    ? (localOffset ? v.replace(' ', 'T') + localOffset : '') : v;
  const ms = Date.parse(text);
  return Number.isFinite(ms) && ms > 0 ? ms / 1000 : null;
}
function timing(reset, start, offset) {
  const end = instant(reset, offset), begin = instant(start, offset);
  return { ...(end !== null ? { resets_at: end } : {}), ...(begin !== null && end > begin ? { period: `${end - begin}s` } : {}) };
}
function counted(label, used, limit, unit, reset, start, offset) {
  const amount = num(used), cap = num(limit);
  if (amount === null || cap === null || amount < 0 || cap < 0) return null;
  return { label, amount, limit: cap, unit, ...(cap > 0 ? { used_percentage: pct(amount / cap * 100), remaining_percentage: 100 - pct(amount / cap * 100) } : {}), ...timing(reset, start, offset) };
}
function measured(label, value, reset, period) {
  const used = num(value);
  return used !== null && used >= 0 && used <= 100 ? { label, used_percentage: used, remaining_percentage: 100 - used, ...timing(reset), ...(period ? { period } : {}) } : null;
}
function add(windows, window) { if (window) windows.push(window); }
function jwt(token) { return parseJSON(Buffer.from(token.split('.')[1] || '', 'base64url').toString('utf8')); }
export function cursorCookie(token) {
  const subject = jwt(token)?.sub, user = typeof subject === 'string' ? subject.split('|').filter(Boolean).at(-1) : '';
  return user && /^[a-zA-Z0-9._-]+$/.test(user) ? `WorkosCursorSessionToken=${encodeURIComponent(`${user}::${token}`)}` : '';
}
export function parseCursor(data, info = {}, hard = {}, grants = {}, enterprise = null) {
  if (!record(data)) return null;
  const windows = [], usage = data.planUsage, reset = data.billingCycleEnd;
  if (record(usage)) {
    if (info.isMerged === true) {
      const period = info.planInfo?.includedUsagePeriod;
      const weekly = period === 'INCLUDED_USAGE_PERIOD_WEEKLY' || period === 2;
      add(windows, measured(weekly ? 'Weekly' : period === 'INCLUDED_USAGE_PERIOD_MONTHLY' || period === 1 ? 'Monthly' : 'Included', usage.totalPercentUsed, reset, weekly ? '7d' : undefined));
    } else {
      for (const [field, label] of [['autoPercentUsed', 'Cursor Models'], ['apiPercentUsed', 'Other Models'], ['totalPercentUsed', 'Total']]) add(windows, measured(label, usage[field], reset));
    }
    const s = data.spendLimitUsage;
    if (record(s) && hard.noUsageBasedAllowed !== true) {
      const own = num(s.individualLimit), pooled = num(s.pooledLimit), hardLimit = num(hard.hardLimit);
      let spent = num(s.individualUsed), cap = own;
      if (own === null && s.limitType === 'team' && pooled > 0) { cap = pooled; spent = num(s.pooledUsed); }
      else if (own === null && s.limitType !== 'team' && hard.noUsageBasedAllowed !== true && hardLimit > 0 && hardLimit < 2147483647) cap = hardLimit * 100;
      if (cap !== null && spent !== null) add(windows, counted('On-demand', spent / 100, cap / 100, 'USD', reset));
    }
  } else if (enterprise?.membershipType?.toLowerCase() === 'enterprise' && enterprise.individualUsage?.overall?.enabled === true) {
    const q = enterprise.individualUsage.overall, used = num(q.used), limit = num(q.limit);
    if (used !== null && limit !== null) add(windows, counted('Enterprise', used / 100, limit / 100, 'USD', enterprise.billingCycleEnd));
    const demand = enterprise.teamUsage?.onDemand;
    if (demand?.enabled === true && num(demand.used) !== null && num(demand.limit) !== null) add(windows, counted('On-demand · Team', Number(demand.used) / 100, Number(demand.limit) / 100, 'USD', enterprise.billingCycleEnd));
  }
  for (const grant of Array.isArray(grants.activeGrants) ? grants.activeGrants : []) {
    const total = num(grant.totalCents), left = num(grant.remainingCents), expires = instant(grant.expiresAtMs);
    if (total === null || left === null || total < 0 || left < 0 || left > total || expires !== null && expires <= Date.now() / 1000) continue;
    const clients = Array.isArray(grant.allowedClientTypes) ? grant.allowedClientTypes.filter(v => typeof v === 'string') : [];
    const label = clients.length && !clients.includes('cli') ? `Free credit · ${clients.join(', ')} only` : 'Free credit';
    const window = counted(label, (total - left) / 100, total / 100, 'USD');
    if (window) { if (expires !== null) window.expires_at = expires; windows.push(window); }
  }
  return windows.length ? { windows, ...(clean(info.planInfo?.planName) ? { plan: clean(info.planInfo.planName).slice(0, 100) } : {}) } : null;
}
export function parseWorkBuddy(summary, enterprise) {
  if (!record(summary)) return null;
  const windows = [], groups = Array.isArray(summary.CreditGroups) ? summary.CreditGroups : [];
  const hasGroups = groups.some(q => num(q?.CycleTotalCapacity) !== null);
  const packs = Array.isArray(summary.Packages) ? summary.Packages : [];
  for (const [i, q] of (hasGroups ? groups : packs).entries()) {
    add(windows, counted(q.Kind === 'plan_base' || q.PackageCode === summary.SubscriptionPackageCode ? 'Credits' : `Extra credits ${i + 1}`, q.CycleUsedCapacity, q.CycleTotalCapacity, 'credits', q.CycleEndTime, q.CycleStartTime, '+08:00'));
  }
  const balances = packs.filter(q => num(q.CycleTotalCapacity) === null && num(q.CycleRemainCapacity) !== null && Number(q.CycleRemainCapacity) >= 0);
  if (balances.length) windows.push({ label: 'Prepaid credits', amount: balances.reduce((n, q) => n + Number(q.CycleRemainCapacity), 0), unit: 'credits', period: 'balance' });
  if (!windows.length && record(enterprise)) add(windows, counted('Enterprise credits', enterprise.credit, enterprise.limitNum, 'credits', enterprise.cycleResetTime, enterprise.cycleStartTime, '+08:00'));
  return windows.length ? { windows, plan: summary.IsPaidUser === true ? 'Pro' : 'WorkBuddy' } : null;
}
export function parseMiMo(subscription, usage) {
  const remaining = num(usage?.percent), reset = instant(usage?.resetDate, '+08:00');
  if (remaining === null || remaining < 0 || remaining > 100 || reset === null) return null;
  const name = clean(subscription?.current?.title) || clean(subscription?.current?.planCode);
  return { windows: [{ label: 'MiMo app', used_percentage: 100 - remaining, remaining_percentage: remaining, period: '7d', resets_at: reset }], ...(name ? { plan: name.slice(0, 100) } : {}) };
}
export function parseTrae(data, cn) {
  if (!record(data) || !Array.isArray(data.user_entitlement_pack_list)) return null;
  const windows = [];
  for (const [i, pack] of data.user_entitlement_pack_list.entries()) {
    const base = pack?.entitlement_base_info, quota = base?.quota, usage = pack?.usage;
    if (!record(quota) || !record(usage)) continue;
    if (cn) {
      const limit = num(quota.credits_limit), used = num(usage.credits_amount);
      if (limit === -1 && used !== null && used >= 0) windows.push({ label: 'Credits', amount: used, unit: 'credits', unlimited: true });
      else add(windows, counted(`Credits ${i + 1}`, used, limit, 'credits', base.end_time ?? base.expire_time ?? pack.end_time));
    } else {
      const basic = num(quota.basic_usage_limit), bonus = num(quota.bonus_usage_limit), used = num(usage.basic_usage_amount), extra = num(usage.bonus_usage_amount);
      // Missing quota/usage counters stay unknown; optional bonus fields must appear as a pair.
      if (basic === null || used === null || basic < 0 || used < 0 || (bonus === null) !== (extra === null) || (bonus ?? 0) < 0 || (extra ?? 0) < 0) continue;
      add(windows, counted(`Dollar Usage ${i + 1}`, used + (extra ?? 0), basic + (bonus ?? 0), 'USD', base.end_time));
    }
  }
  return windows.length ? { windows } : null;
}
const messages = {
  'no-auth': '请选择此账号的有效明文 Auth JSON 导出文件；不会读取其他账号或自动登录。',
  'no-query': '此类型仅支持已有 Auth 文件的额度查询。',
  encrypted: 'WorkBuddy 5.6 及以上的加密凭证暂不支持；请选择原客户端提供的有效明文 Auth 导出。',
  session: 'MiMo 需要同一登录导出内已有的有效 app session；仅 passToken 或过期 session 暂不支持，不自动重定向登录。',
  region: '认证地域或账号上下文不匹配，请选择此类型对应的 Auth 导出。',
  auth: '授权无效、过期或无额度权限，请由原客户端更新后重新查询。',
  parse: '服务端未返回可识别的真实用量，当前额度未知。',
  network: '额度查询暂时失败，请稍后重试。', ratelimit: '额度接口限流，请稍后重试。',
};
export function main() {
  const id = process.env.TOKENHUD_DESKTOP_PROVIDER, config = desktopProviders[id];
  const hud = process.env.TOKENHUD_HUD_DIR || join(homedir(), '.claude', 'hud');
  const cache = process.env.TOKENHUD_CACHE_FILE || process.env.USAGE_CACHE_FILE || join(hud, `.${id}-usage-cache.json`);
  const secrets = [];
  const emit = value => {
    const text = JSON.stringify(value, (_key, item) => typeof item === 'string' ? secrets.filter(Boolean).reduce((s, token) => s.split(token).join('[redacted]'), item) : item);
    if (process.env.TOKENHUD_STDOUT_ONLY === '1') process.stdout.write(text + '\n');
    else { mkdirSync(dirname(cache), { recursive: true }); writeFileSync(cache, text); }
  };
  // The native engine retains last-good values only after checking the account source.
  const fail = code => emit({ error: code, message: messages[code] || messages.network, stale: true, lastAttemptAt: Date.now(), ttlMs: 60_000 });
  try {
    if (!config) throw new Error('no-query');
    const snapshot = process.env.TOKENHUD_AUTH_FILE ? readJSON(process.env.TOKENHUD_AUTH_FILE) : null;
    if (snapshot?.authMode && snapshot.authMode !== 'auth') throw new Error('no-query');
    const context = snapshot?.tokenhudAuthContext ?? {}, key = clean(snapshot?.queryKey);
    if (!record(context) || Object.values(context).some(v => typeof v !== 'string' || /[\x00-\x1f\x7f]/.test(v))) throw new Error('no-auth');
    if (!key) throw new Error(id.startsWith('workbuddy') ? 'encrypted' : id === 'xiaomi-mimo-desktop' ? 'session' : 'no-auth');
    secrets.push(key, ...Object.values(context));
    if (context.sourceProvider) {
      // Magpie's workbuddy means CN; TokenHUD's workbuddy means international.
      // Resolve that collision only with an explicit international domain.
      const source = context.sourceProvider;
      const matches = id === 'workbuddy-cn' ? ['workbuddy-cn', 'workbuddy'].includes(source)
        : id === 'workbuddy' ? source === 'workbuddy-ai' || source === 'workbuddy' && ['www.workbuddy.ai', 'https://www.workbuddy.ai'].includes(context.domain)
        : source === id || id === 'trae' && source === 'trae-global' || id === 'xiaomi-mimo-desktop' && source === 'mimo-app';
      if (!matches) throw new Error('region');
    }
    const expiry = instant(context.expiresAt) ?? num(jwt(key)?.exp);
    if (expiry !== null && expiry <= Date.now() / 1000) throw new Error('auth');
    const deadline = Date.now() + 22_000;
    const allowed = new Set([config.host]);
    if (id === 'cursor') allowed.add('https://cursor.com');
    if (id === 'trae') allowed.add('https://api-us-east.trae.ai');
    if (id === 'xiaomi-mimo-desktop') for (const region of ['sgp', 'ru', 'in']) allowed.add(`https://mimo-server-${region}.xiaomimimo.com`);
    const request = (url, headers, body, method = 'POST') => {
      if (method === 'POST' && body === undefined) body = {};
      const u = new URL(url), seconds = Math.min(7, (deadline - Date.now()) / 1000);
      if (u.protocol !== 'https:' || !allowed.has(u.origin) || u.username || u['pass' + 'word'] || seconds <= 0) throw new Error(seconds <= 0 ? 'network' : 'region');
      const args = ['-q', '-sS', '--connect-timeout', '3', '--max-time', String(seconds), '--proto', '=https', '--max-redirs', '0', '-X', method, '-H', 'Accept: application/json'];
      for (const [name, value] of Object.entries(headers)) { if (!clean(value)) throw new Error('no-auth'); args.push('-H', `${name}: ${value}`); }
      if (body !== undefined) args.push('-H', 'Content-Type: application/json', '--data-binary', JSON.stringify(body));
      args.push('-w', '\n%{http_code}', '--url', u.toString());
      const result = spawnSync(process.env.TOKENHUD_CURL || '/usr/bin/curl', args, { encoding: 'utf8', timeout: Math.ceil(seconds * 1000) + 500, killSignal: 'SIGKILL', maxBuffer: 2_000_000, stdio: ['ignore', 'pipe', 'pipe'] });
      if (result.error || result.status !== 0) throw new Error('network');
      const split = result.stdout.lastIndexOf('\n'), status = Number(result.stdout.slice(split + 1));
      if ([401, 403].includes(status)) throw new Error('auth');
      if (status === 429) throw new Error('ratelimit');
      if (split < 0 || !Number.isInteger(status) || status < 200 || status >= 300) throw new Error('network');
      const data = parseJSON(result.stdout.slice(0, split));
      if (!record(data)) throw new Error('parse');
      const code = data.code ?? data.Code ?? data.ResponseMetadata?.Error?.Code;
      if (data.error || code !== undefined && code !== 0 && code !== '0') throw new Error([401, 403, 1001, 20101, '401', '403', '1001', '20101'].includes(code) ? 'auth' : 'parse');
      return data;
    };
    const optional = fn => { try { return fn(); } catch { return {}; } };
    let usage;
    if (id === 'cursor') {
      const headers = { Authorization: `Bearer ${key}`, 'Connect-Protocol-Version': '1', 'x-cursor-client-version': 'cli-2026.09.23-86fc751', 'x-cursor-client-type': 'cli', 'x-ghost-mode': 'true' };
      if (context.teamId) {
        if (!context.authId || context.authId !== jwt(key)?.sub) throw new Error('region');
        headers['x-cursor-team-id'] = context.teamId;
      }
      const data = request(config.host + config.path, headers);
      const info = optional(() => request(config.host + '/aiserver.v1.DashboardService/GetPlanInfo', headers));
      const hard = optional(() => request(config.host + '/aiserver.v1.DashboardService/GetHardLimit', headers));
      const grants = optional(() => request(config.host + '/aiserver.v1.DashboardService/GetUsageLimitStatusAndActiveGrants', headers));
      let enterprise;
      if (!record(data.planUsage)) {
        // The dashboard endpoint has no team selector: never drop a selected team's scope.
        const cookie = cursorCookie(key);
        if (cookie && !context.teamId) { secrets.push(cookie); enterprise = optional(() => request('https://cursor.com/api/usage-summary', { Cookie: cookie, Origin: 'https://cursor.com' }, undefined, 'GET')); }
      }
      usage = parseCursor(data, info, hard, grants, enterprise);
    } else if (id.startsWith('workbuddy')) {
      if (!context.userId) throw new Error('no-auth');
      const domain = context.domain || new URL(config.host).host;
      if (/^https?:\/\//i.test(domain) ? new URL(domain).origin !== config.host : /\./.test(domain) && domain !== new URL(config.host).host) throw new Error('region');
      const headers = { Authorization: `Bearer ${key}`, 'User-Agent': 'WorkBuddy/5.9.3', 'X-User-Id': context.userId, 'X-Domain': domain, 'X-Product': 'SaaS', 'X-IDE-Type': 'WorkBuddy' };
      if (context.enterpriseId) Object.assign(headers, { 'X-Enterprise-Id': context.enterpriseId, 'X-Tenant-Id': context.enterpriseId });
      const summary = request(config.host + config.path, headers).data;
      usage = parseWorkBuddy(summary);
      if (!usage) usage = parseWorkBuddy(summary, request(config.host + '/billing/meter/get-enterprise-user-usage', headers).data);
    } else if (id === 'xiaomi-mimo-desktop') {
      const cookies = parseJSON(key), creds = parseJSON(context.xiaomiCredentials || '{}');
      if (!record(cookies) || !clean(cookies.serviceToken)) throw new Error('session');
      const region = (context.region || creds?.region || 'SGP').toUpperCase(), hosts = { SGP: 'https://mimo-server-sgp.xiaomimimo.com', RU: 'https://mimo-server-ru.xiaomimimo.com', IN: 'https://mimo-server-in.xiaomimimo.com' };
      const host = hosts[region];
      if (!host || creds?.base && creds.base.replace(/\/+$/, '') !== host + '/api') throw new Error('region');
      const order = [...new Set(['serviceToken', 'userId', 'cUserId', ...Object.keys(cookies)])];
      const parts = [];
      for (const name of order) {
        if (!(name in cookies)) continue;
        const value = clean(cookies[name]);
        if (!/^[a-zA-Z0-9_-]+$/.test(name) || !value || /[;\r\n]/.test(value)) throw new Error('session');
        secrets.push(value); parts.push(`${name}=${value}`);
      }
      const cookie = parts.join('; '); secrets.push(cookie);
      const headers = { Cookie: cookie, 'User-Agent': 'miNative PC/Normal Windows_NT/10.0.26100 SDKV/1.0.0 DEVT/PC DEVS/Windows APP/miaccount_desktop APPV/0.1.0', 'X-Client-Version': '26.929.292248' };
      const self = request(host + '/api/user/xiaomi/subscription/self', headers, undefined, 'GET');
      const data = request(host + '/api/user/usage', headers, undefined, 'GET');
      usage = parseMiMo(self.data, data.data);
    } else {
      const cn = id === 'trae-cn';
      if (!context.userId || !context.deviceId || !context.machineId) throw new Error('no-auth');
      if (context.authHost && new URL(context.authHost).hostname.endsWith(cn ? '.trae.ai' : '.trae.cn')) throw new Error('region');
      const host = !cn && (/^US(?:[-_ ]|$)/i.test(context.region || '') || /api-us/i.test(context.api || '')) ? 'https://api-us-east.trae.ai' : config.host;
      const headers = { Authorization: `Cloud-IDE-JWT ${key}`, 'X-Cloudide-Token': key, 'x-ide-token': key, 'x-uid': context.userId, 'x-app-id': '6eefa01c-1036-4c7e-9ca5-d891f63bfcd8', 'x-device-id': context.deviceId, 'x-machine-id': context.machineId, 'x-request-id': randomUUID(), 'x-app-version': '0.1.69', 'x-app-version-code': '20260917', 'x-ide-version': '0.1.69', 'x-ide-version-code': '20260917', 'x-ide-version-type': 'stable', 'x-device-cpu': 'AMD', 'x-device-brand': 'ASUS TUF Gaming A15 FA507RM_FA507RM', 'x-device-type': 'windows', 'x-os-version': 'Windows 10', 'x-system-type': 'Windows' };
      usage = parseTrae(request(host + config.path, headers, cn ? { require_usage: true, req_source: 0 } : {}), cn);
    }
    if (!usage) throw new Error('parse');
    emit({ ...usage, generatedAt: Date.now(), ttlMs: 60_000, error: null, stale: false });
  } catch (error) { fail(Object.hasOwn(messages, error.message) ? error.message : 'parse'); }
}
if (process.argv[1] && realpathSync(resolve(process.argv[1])) === realpathSync(fileURLToPath(import.meta.url))) main();
