#!/usr/bin/env node
// Endpoint/field facts independently adapted from magpie-community/plugins
// 3e24e228377ed17a9e5991c4e715dfde0244a1ea. No upstream implementation copied.
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash, createHmac, randomUUID } from 'node:crypto';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

export const enterpriseProviders = Object.freeze({
  codearts: { url: 'https://snap-access.cn-north-4.myhuaweicloud.com/snap-manager/v1/statistics/plugin', modes: ['auth'] },
  officeace: { url: 'https://officeace.cn-southwest-2.huaweicloud-agentarts.com/v1/subscription', modes: ['auth'] },
  qwenwork: { url: 'https://gateway.qwenwork.cn/api/v1/adapter/user/account-context?include=user,plan,quota', modes: ['auth'] },
  'qwenwork-enterprise': { modes: ['auth'] },
  orcaterm: { url: 'https://orcaterm.com/cgi/api', modes: ['auth'] },
  'cloudflare-workers-ai': { url: 'https://api.cloudflare.com/client/v4/graphql', modes: ['auth', 'apikey'] },
});
const object = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const clean = v => typeof v === 'string' && !/[\x00-\x1f\x7f]/.test(v) ? v.trim() : '';
const number = v => {
  if (!['number', 'string'].includes(typeof v) || (typeof v === 'string' && !v.trim())) return null;
  const n = Number(v); return Number.isFinite(n) && n >= 0 ? n : null;
};
const instant = v => {
  if (typeof v !== 'string' || !/^\d{4}-\d\d-\d\d(?:T| )/.test(v)) return null;
  const n = Date.parse(v); return Number.isFinite(n) && n > 0 ? Math.floor(n / 1000) : null;
};
const meter = (label, used, limit, unit = 'credits') => ({ label, ...(used !== null ? { amount: used } : {}), ...(limit !== null ? { limit } : {}), ...(used !== null && limit > 0 ? { used_percentage: Math.min(100, 100 * used / limit) } : {}), unit });
const balance = (label, amount) => ({ label, amount, unit: 'credits', period: 'balance' });
const unwrap = v => object(v?.data) ? v.data : v;
export function enterpriseOrigin(value) {
  const text = clean(value).toLowerCase();
  if (!text) return null;
  let url;
  try { url = new URL(text.includes('://') ? text : `https://${text}`); } catch { return null; }
  if (url.protocol !== 'https:' || url.username || url['pass' + 'word'] || url.port || url.search || url.hash || url.pathname !== '/') return null;
  const host = url.hostname;
  if (![host, url.origin, `${url.origin}/`].includes(text)) return null;
  if (!/^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/.test(host) || /(?:^|\.)(?:localhost|local|internal)$/.test(host) || host === 'gateway.qwenwork.cn') return null;
  // No redirect, host discovery or alternate domains: this explicit origin is the only destination.
  return url.origin;
}
export function parseEnterpriseUsage(provider, raw, extra) {
  if (!object(raw)) return null;
  const windows = [];
  if (provider === 'codearts') {
    if (raw.code !== undefined && raw.code !== 0) return null;
    const data = unwrap(raw);
    const names = { usageTotalPackageCredit: '总积分', usageBasicPackageCredit: '基础积分包', usageOnDemandPackageCredit: '按需积分包', usageBonusPackageCredit: '赠送积分包' };
    for (const row of Array.isArray(data?.metrics) ? data.metrics : []) {
      if (!names[row?.name]) continue;
      const limit = number(row.package_credit_amount), left = number(row.package_credit_remain);
      if (left === null) continue;
      const w = limit !== null ? meter(names[row.name], Math.max(0, limit - left), limit) : balance(`${names[row.name]}余额`, left);
      const at = instant(data.end_date);
      if (at !== null && ['usageTotalPackageCredit', 'usageBasicPackageCredit'].includes(row.name)) w.resets_at = at;
      windows.push(w);
    }
    // A separate daily free-token pool uses the same STS credential, not package credits.
    const free = object(extra?.result) ? extra.result : object(extra?.data) ? extra.data : extra;
    const freeLimit = number(free?.daily_token_limit), freeUsed = number(free?.daily_tokens_used);
    if (freeLimit !== null && freeUsed !== null) {
      const shifted = new Date(Date.now() + 8 * 3_600_000); shifted.setUTCHours(24, 0, 0, 0);
      windows.push({ ...meter('每日免费 Tokens', freeUsed, freeLimit, 'tokens'), period: 'daily', resets_at: Math.floor((shifted.getTime() - 8 * 3_600_000) / 1000) });
    }
  } else if (provider === 'officeace') {
    const add = (label, usedRaw, totalRaw, expiry, trial) => {
      const used = number(usedRaw), total = number(totalRaw);
      if (used === null) return;
      const w = meter(label, used, total);
      // Bucket expiration is not a replenishment/reset timestamp.
      const at = trial ? null : instant(expiry);
      if (at !== null && at * 1000 <= Date.now()) return;
      if (at !== null) w.label += ` · 到期 ${new Date(at * 1000).toISOString()}`;
      windows.push(w);
    };
    for (const sku of Array.isArray(raw.skus) ? raw.skus : []) {
      for (const q of Array.isArray(sku?.quotas) ? sku.quotas : []) {
        if (q?.sku_attr_code === 'officeace_points') add(clean(sku.sku_name) || '套餐积分', q.current_value, q.sku_value, q.expired_time, String(sku.sku_code ?? '').endsWith('.trial'));
      }
    }
    for (const q of Array.isArray(raw.bonus_skus) ? raw.bonus_skus : []) add(clean(q?.activity_name) || '活动积分', q?.current_value, q?.points, q?.expired_time, false);
  } else if (provider.startsWith('qwenwork')) {
    const data = unwrap(raw), q = data?.quota;
    if (object(q)) {
      const total = number(q.total), left = number(q.remaining);
      const used = number(q.used) ?? (total !== null && left !== null && left <= total ? total - left : null);
      if (used !== null) windows.push(meter('Credits', used, total));
      if (left !== null) windows.push(balance('可用积分余额', left));
    }
    const wallets = unwrap(extra);
    for (const [key, label] of [['daily_credits', '每日积分余额'], ['monthly_credits', '每月积分余额'], ['longterm_credits', '长期积分余额']]) {
      const value = number(wallets?.[key]?.total_balance ?? wallets?.[key]?.totalBalance);
      if (value !== null) windows.push(balance(label, value));
    }
  } else if (provider === 'orcaterm') {
    const data = raw.data?.Response ?? raw.Response;
    if (!object(data) || data.Error) return null;
    for (const row of Array.isArray(data.usageStats) ? data.usageStats : []) {
      if (row?.feature !== 'hunyuan_ai') continue;
      const used = number(row.quotaUsed), limit = number(row.quotaLimit);
      if (used === null) continue;
      const w = meter('AI Q&A', used, limit, 'questions'), at = instant(row.quotaEndDate);
      if (at !== null) w.resets_at = at;
      windows.push(w);
    }
  } else if (provider === 'cloudflare-workers-ai') {
    if (Array.isArray(raw.errors) && raw.errors.length) return null;
    const accounts = raw.data?.viewer?.accounts;
    // The query selects exactly one account; absent/multiple accounts are unknown.
    if (!Array.isArray(accounts) || accounts.length !== 1) return null;
    const rows = accounts[0]?.aiInferenceAdaptiveGroups;
    if (!Array.isArray(rows)) return null;
    let used = 0;
    for (const row of rows) { const n = number(row?.sum?.totalNeurons); if (n === null) return null; used += n; }
    if (!Number.isFinite(used)) return null;
    // Analytics reports usage, not an account's authoritative allowance limit.
    windows.push({ ...meter('今日 Neurons · 上限未知', used, null, 'neurons'), period: 'daily', resets_at: extra });
  }
  return windows.length ? { windows } : null;
}
const hash = text => createHash('sha256').update(text).digest('hex');
const hmac = (key, text, encoding) => createHmac('sha256', key).update(text).digest(encoding);
export function signHuawei(provider, urlText, key, ctx, date = new Date()) {
  const url = new URL(urlText), stamp = date.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  const headers = provider === 'officeace'
    ? { host: url.host, 'x-sdk-date': stamp, 'x-security-token': ctx.securityToken, 'x-subscription-type': 'v2', ...(ctx.projectId ? { 'x-project-id': ctx.projectId } : {}) }
    : { host: url.host, 'x-sdk-date': stamp, 'x-security-token': ctx.securityToken, 'x-sdk-content-sha256': hash('') };
  const names = Object.keys(headers).sort();
  const canonical = ['GET', `${url.pathname.replace(/\/$/, '')}/`, '', names.map(n => `${n}:${headers[n].trim().replace(/\s+/g, ' ')}\n`).join(''), names.join(';'), hash('')].join('\n');
  let authorization;
  if (provider === 'officeace') {
    const scope = `${stamp.slice(0, 8)}/cn-southwest-2/apic`;
    const derived = hmac(hmac(key, ctx.secretAccessKey), Buffer.concat([Buffer.from(scope), Buffer.from([1])]), 'hex');
    const signature = hmac(derived, `V11-HMAC-SHA256\n${stamp}\n${scope}\n${hash(canonical)}`, 'hex');
    authorization = `V11-HMAC-SHA256 Credential=${key}/${scope}, SignedHeaders=${names.join(';')}, Signature=${signature}`;
  } else {
    const signature = hmac(ctx.secretAccessKey, `SDK-HMAC-SHA256\n${stamp}\n${hash(canonical)}`, 'hex');
    authorization = `SDK-HMAC-SHA256 Access=${key},SignedHeaders=${names.join(';')},Signature=${signature}`;
  }
  return { ...headers, Authorization: authorization, ...(provider === 'codearts' && url.hostname === 'snap-access.cn-north-4.myhuaweicloud.com' ? { 'Agent-Type': 'PromptCenter', 'X-Language': 'zh-cn' } : {}) };
}
function request(url, headers, body) {
  const args = ['-q', '-sS', '--connect-timeout', '3', '--max-time', '15', '--proto', '=https', '-X', body === undefined ? 'GET' : 'POST'];
  for (const [name, value] of Object.entries(headers)) args.push('-H', `${name}: ${value}`);
  if (body !== undefined) args.push('--data-binary', JSON.stringify(body));
  args.push('-w', '\n%{http_code}', '--url', url);
  const r = spawnSync(process.env.TOKENHUD_CURL || '/usr/bin/curl', args, { encoding: 'utf8', timeout: 16_000, killSignal: 'SIGKILL', maxBuffer: 2_000_000, stdio: ['ignore', 'pipe', 'pipe'] });
  if (r.error || r.status !== 0) throw new Error('network');
  const cut = r.stdout.lastIndexOf('\n'), status = Number(r.stdout.slice(cut + 1).trim());
  if (status === 401 || status === 403) throw new Error('auth');
  if (status === 429) throw new Error('ratelimit');
  if (status !== 200) throw new Error('network');
  try { return JSON.parse(r.stdout.slice(0, cut)); } catch { throw new Error('parse'); }
}
const readJSON = file => { try { return JSON.parse(readFileSync(file, 'utf8')); } catch { return null; } };
export function main() {
  const provider = process.env.USAGE_PROVIDER_NAME, config = enterpriseProviders[provider];
  const hud = process.env.TOKENHUD_HUD_DIR || join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'hud');
  const authFile = process.env.TOKENHUD_AUTH_FILE || process.env.USAGE_AUTH_FILE;
  const cacheFile = process.env.TOKENHUD_CACHE_FILE || process.env.USAGE_CACHE_FILE || join(hud, `.${provider}-usage-cache.json`);
  const emit = output => {
    if (process.env.TOKENHUD_STDOUT_ONLY === '1') process.stdout.write(JSON.stringify(output) + '\n');
    else { mkdirSync(dirname(cacheFile), { recursive: true }); writeFileSync(cacheFile, JSON.stringify(output, null, 2)); }
  };
  const fail = (error, message) => emit({ error, ...(message ? { message } : {}), stale: true, lastAttemptAt: Date.now(), ttlMs: 60_000 });
  if (!config) { fail('no-query'); return; }
  // Only the selected, resolved snapshot is read. External auth paths are not followed.
  const snapshot = authFile ? readJSON(authFile) : null;
  const key = clean(snapshot?.queryKey);
  if (!key) { fail('no-auth', '缺少当前账号的基础认证。'); return; }
  if (!config.modes.includes(snapshot.authMode)) { fail('no-query', '此类型额度查询不支持当前基础认证方式。'); return; }
  const ctx = Object.create(null);
  for (const [k, v] of Object.entries(object(snapshot.tokenhudAuthContext) ? snapshot.tokenhudAuthContext : {})) {
    if (typeof v !== 'string' || !clean(v)) { fail('no-auth', '授权上下文字段无效。'); return; }
    ctx[k] = clean(v);
  }
  try {
    let raw, extra;
    if (['codearts', 'officeace'].includes(provider)) {
      if (!ctx.secretAccessKey || !ctx.securityToken) { fail('no-auth', '授权文件须包含同一临时 credential 的 AK、SK、security token。'); return; }
      raw = request(config.url, signHuawei(provider, config.url, key, ctx));
      if (provider === 'codearts') {
        const benefitUrl = 'https://opengw.developer.huaweicloud.com/api/v1/user/tokens/balance';
        try { extra = request(benefitUrl, signHuawei(provider, benefitUrl, key, ctx)); } catch { /* Optional free pool does not replace known package statistics. */ }
      }
    } else if (provider.startsWith('qwenwork')) {
      let base = 'https://gateway.qwenwork.cn';
      if (provider === 'qwenwork-enterprise') {
        const origin = enterpriseOrigin(ctx.enterpriseHost);
        if (!origin) { fail('no-auth', '请选择包含明确企业 enterpriseHost HTTPS 域名的授权文件。'); return; }
        base = origin;
      } else if (ctx.enterpriseHost) { fail('no-auth', '企业凭证请使用 QwenWork Enterprise 类型。'); return; }
      const headers = { Accept: 'application/json', Authorization: `Bearer ${key}`, 'User-Agent': 'qoderwork/1.2.1', 'X-Request-Id': randomUUID(), 'X-QwenWork-Version': '1.2.1', 'X-QwenWork-Release-Version': '1.2.1-26092107', 'X-QwenWork-Build': '26092107', 'X-QwenWork-Platform': 'darwin', 'X-QwenWork-Arch': process.arch, 'X-QwenWork-Channel': 'stable' };
      raw = request(`${base}/api/v1/adapter/user/account-context?include=user,plan,quota`, headers);
      const user = unwrap(raw)?.user;
      if (provider === 'qwenwork' && user?.is_biz !== true && user?.isBiz !== true) {
        try { extra = request(`${base}/api/v1/adapter/user/wallets`, headers); } catch { /* Optional breakdown: the main quota remains authoritative. */ }
      }
    } else if (provider === 'orcaterm') {
      // The same OAuth token becomes the product's session cookie, without browser auth.
      if (!/^[A-Za-z0-9._~-]+$/.test(key)) { fail('no-auth', '需要 OrcaTerm OAuth access token；不支持独立控制台 Cookie。'); return; }
      const seq = `${Date.now()}-${randomUUID()}`;
      raw = request(`${config.url}?action=DescribeUserBillingStatus&t=${seq}`, { Accept: 'application/json', 'Content-Type': 'application/json', 'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8', 'x-seqid': seq, Origin: 'https://orcaterm.com', Referer: 'https://orcaterm.com/terminal', 'x-referer': 'https://orcaterm.com/terminal', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36', Cookie: `ot_session=${key}` }, { action: 'DescribeUserBillingStatus', data: {} });
    } else if (provider === 'cloudflare-workers-ai') {
      if (ctx.accountId && ctx.metadataAccountId && ctx.accountId.toLowerCase() !== ctx.metadataAccountId.toLowerCase()) { fail('account-selection-required', '授权文件中两个 accountId 不一致，请明确选择账户。'); return; }
      let accountId = ctx.accountId || ctx.metadataAccountId;
      const headers = { Authorization: `Bearer ${key}`, Accept: 'application/json' };
      if (!accountId) {
        const discovery = request('https://api.cloudflare.com/client/v4/accounts', headers);
        if (discovery.success !== true || !Array.isArray(discovery.result)) { fail('no-auth', '同一 token 无法发现 accountId；请在 Auth 文件中提供 accountId。'); return; }
        const count = number(discovery.result_info?.total_count);
        if (discovery.result.length !== 1 || (count !== null && count !== 1) || number(discovery.result_info?.total_pages) > 1) { fail('account-selection-required', '发现多个或没有可用账户；请在 Auth 文件中明确填写所选 accountId。'); return; }
        accountId = discovery.result[0]?.id;
      }
      if (!/^[0-9a-f]{32}$/i.test(accountId || '')) { fail('no-auth', 'accountId 须为同一 token 可访问账户的 32 位十六进制 ID。'); return; }
      const end = new Date(); end.setUTCHours(24, 0, 0, 0);
      const start = new Date(end.getTime() - 86_400_000);
      extra = Math.floor(end.getTime() / 1000);
      raw = request(config.url, { ...headers, 'Content-Type': 'application/json' }, { query: `query { viewer { accounts(filter: {accountTag: "${accountId}"}) { aiInferenceAdaptiveGroups(limit: 100, filter: {datetimeHour_geq: "${start.toISOString()}", datetimeHour_lt: "${end.toISOString()}"}) { sum { totalNeurons } } } } }` });
    }
    const usage = parseEnterpriseUsage(provider, raw, extra);
    if (!usage) { fail('parse', provider === 'cloudflare-workers-ai' ? '无法读取真实用量；请检查同一 token 的 Account Analytics Read 权限。上限未知。' : '服务端未返回可识别额度，当前用量未知。'); return; }
    emit({ ...usage, generatedAt: Date.now(), ttlMs: 60_000, error: null, stale: false });
  } catch (e) { fail(['network', 'auth', 'ratelimit', 'parse'].includes(e.message) ? e.message : 'parse'); }
}
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main();
