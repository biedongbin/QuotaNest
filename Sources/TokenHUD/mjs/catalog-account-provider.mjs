#!/usr/bin/env node
// Independent TokenHUD adapters from the wire contracts in 9router at 1066c362.
// Read only the core's selected-account snapshot; never discover logins or refresh tokens.
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

export const accountProviders = Object.freeze({
  qoder: { source: 'qoder', host: 'https://openapi.qoder.sh', region: 'intl' },
  'qoder-cn': { source: 'qoder-cn', host: 'https://openapi.qoder.com.cn', region: 'cn' },
  kiro: { source: 'kiro', host: 'https://codewhisperer.us-east-1.amazonaws.com' },
  'minimax-code-cn': { source: 'minimax-code', host: 'https://agent.minimaxi.com', platform: 'https://www.minimaxi.com', lang: 'zh' },
  'minimax-code': { source: 'minimax-code-global', host: 'https://agent.minimax.io', platform: 'https://platform.minimax.io', lang: 'en' },
  zed: { source: 'zed', host: 'https://cloud.zed.dev' },
});
const number = v => ['string', 'number'].includes(typeof v) && String(v).trim() && Number.isFinite(Number(v)) ? Number(v) : null;
const clean = v => typeof v === 'string' && !/[\x00-\x1f\x7f]/.test(v) ? v.trim() : '';
const record = v => v !== null && typeof v === 'object' && !Array.isArray(v);
export function timestamp(v) {
  const n = number(v);
  if (n !== null) return n > 0 ? n >= 1e12 ? n / 1000 : n : null;
  const ms = typeof v === 'string' && /^\d{4}-\d{2}-\d{2}(?:T|$)/.test(v) ? Date.parse(v) : NaN;
  return Number.isFinite(ms) && ms > 0 ? ms / 1000 : null;
}
const pct = n => Math.max(0, Math.min(100, n));
function counted(label, usedValue, limitValue, unit, reset, period) {
  const amount = number(usedValue), limit = number(limitValue);
  if (amount === null || limit === null || amount < 0 || limit < 0) return null;
  return { label, amount, limit, unit, ...(period ? { period } : {}),
    ...(limit > 0 ? { used_percentage: pct(amount / limit * 100), remaining_percentage: 100 - pct(amount / limit * 100) } : {}),
    ...(timestamp(reset) !== null ? { resets_at: timestamp(reset) } : {}) };
}
export function parseQoder(data) {
  if (!record(data) || data.error) return null;
  const windows = [];
  for (const [name, label] of [['userQuota', '个人额度'], ['orgResourcePackage', '组织额度']]) {
    const q = data[name];
    if (!record(q)) continue;
    const total = number(q.total), remaining = number(q.remaining);
    const used = number(q.used) ?? (total !== null && remaining !== null ? total - remaining : null);
    const w = counted(label, used, total, clean(q.unit) || 'credits');
    if (w) windows.push(w);
  }
  // expiresAt is an expiry, not evidence of a renewable reset window.
  return windows.length ? { windows, ...(timestamp(data.expiresAt) !== null ? { expires_at: timestamp(data.expiresAt) } : {}),
    ...(typeof data.isQuotaExceeded === 'boolean' ? { limitReached: data.isQuotaExceeded } : {}) } : null;
}
export function parseKiro(data) {
  if (!record(data) || data.error || !Array.isArray(data.usageBreakdownList)) return null;
  const windows = [];
  for (const q of data.usageBreakdownList) {
    const resource = clean(q?.resourceType);
    if (!resource) continue;
    // No assumed dollar conversion: preserve the reported resource unit.
    const unit = clean(q.unit) || resource;
    const main = counted(resource, q.currentUsageWithPrecision, q.usageLimitWithPrecision, unit, data.nextDateReset ?? data.resetDate);
    if (main) windows.push(main);
    const t = q.freeTrialInfo;
    if (record(t)) {
      const trial = counted(`${resource} · 试用（到期）`, t.currentUsageWithPrecision, t.usageLimitWithPrecision, unit, null, 'expiry');
      if (trial) { if (timestamp(t.freeTrialExpiry) !== null) trial.expires_at = timestamp(t.freeTrialExpiry); windows.push(trial); }
    }
  }
  return windows.length ? { windows, ...(clean(data.subscriptionInfo?.subscriptionTitle) ? { plan: clean(data.subscriptionInfo.subscriptionTitle) } : {}) } : null;
}
export function parseZed(data) {
  if (!record(data?.plan?.usage) || data.error) return null;
  const windows = [], plan = data.plan;
  for (const [snake, camel, label] of [['edit_predictions', 'editPredictions', 'Edit Predictions'], ['model_requests', 'modelRequests', 'Hosted Model Requests']]) {
    const q = plan.usage[snake] ?? plan.usage[camel];
    if (!record(q)) continue;
    const amount = number(q.used), raw = q.limit;
    if (amount === null || amount < 0) continue;
    if (raw === 'unlimited' || raw?.unlimited === true) { windows.push({ label, amount, unit: 'requests', unlimited: true }); continue; }
    const limit = number(record(raw) ? raw.limited ?? raw.Limited : raw);
    // Model limit zero denotes token billing; this endpoint supplies no token spend.
    if (snake === 'model_requests' && limit === 0) continue;
    const w = counted(label, amount, limit, 'requests', plan.subscription_period?.ended_at ?? plan.subscriptionPeriod?.endedAt);
    if (w) windows.push(w);
  }
  return windows.length ? { windows, ...(clean(plan.plan_v3 ?? plan.plan_v2 ?? plan.plan) ? { plan: clean(plan.plan_v3 ?? plan.plan_v2 ?? plan.plan) } : {}),
    ...(plan.has_overdue_invoices === true ? { message: '此账号有逾期账单。' } : {}) } : null;
}
function membership(data) {
  const root = record(data?.data) ? data.data : data;
  const summary = root?.op_credit_summary;
  return { hasPlan: root?.has_token_plan, group: clean(root?.op_group_id), tier: clean(root?.token_plan_tier),
    balance: number(summary?.total_remaining_amount ?? root?.opcredit_balance), expires: timestamp(root?.token_plan_expires_at) };
}
export function parseMiniMaxCode(info, planBody) {
  const m = membership(info), windows = [];
  if (m.balance !== null && m.balance >= 0) windows.push({ label: '剩余 Credits', amount: m.balance, unit: 'credits', period: 'balance' });
  for (const q of Array.isArray(planBody?.model_remains) ? planBody.model_remains : []) {
    const name = clean(q?.model_name);
    if (!name) continue;
    for (const weekly of [false, true]) {
      const prefix = weekly ? 'current_weekly' : 'current_interval', status = number(q[`${prefix}_status`]);
      if (status === 3) continue;
      const remaining = status === 2 ? 0 : number(q[`${prefix}_remaining_percent`]);
      if (remaining === null || remaining < 0 || remaining > 100) continue;
      const start = timestamp(q[weekly ? 'weekly_start_time' : 'start_time']);
      const end = timestamp(q[weekly ? 'weekly_end_time' : 'end_time']);
      const seconds = start !== null && end > start ? end - start : null;
      const period = seconds !== null ? seconds % 3600 === 0 ? `${seconds / 3600}h` : `${seconds}s` : weekly ? '7d' : null;
      windows.push({ label: `${name} · ${period || '额度'}`, used_percentage: 100 - remaining, remaining_percentage: remaining,
        ...(period ? { period } : {}), ...(end !== null ? { resets_at: end } : {}) });
    }
  }
  return windows.length ? { windows, ...(m.tier ? { plan: m.tier } : {}), ...(m.expires !== null ? { expires_at: m.expires } : {}) } : null;
}
// Public client protocol constant, not a user credential; copied as a wire literal only.
const MCODE_SIGNATURE_CONSTANT = "I*7Cf%WZ#S&%1RlZJ&C2";
const md5 = text => createHash('md5').update(text).digest('hex');
export function signedMiniMaxRequest(config, path, token, userId, body, now = Date.now()) {
  const url = new URL(path, config.host);
  url.search = new URLSearchParams({ device_platform: 'mcode', biz_id: '3', app_id: '3001', version_code: '22201', unix: String(now),
    timezone_offset: String(-new Date().getTimezoneOffset() * 60), sys_language: config.lang, lang: config.lang,
    device_id: '0', os_name: process.platform, browser_name: 'mcode', user_id: userId || '0', client: 'mcode' }).toString();
  const text = body === undefined ? undefined : JSON.stringify(body), ts = String(Math.floor(now / 1000));
  return { url: url.toString(), method: text === undefined ? 'GET' : 'POST', body,
    headers: { Authorization: `Bearer ${token}`, 'User-Agent': 'MiniMaxCode',
      yy: md5(`${encodeURIComponent(url.pathname + url.search)}_${text ?? '{}'}${md5(String(now))}ooui`),
      'x-timestamp': ts, 'x-signature': md5(ts + MCODE_SIGNATURE_CONSTANT + (text ?? '')) } };
}
const readJSON = path => { try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; } };
export function main() {
  const id = process.env.TOKENHUD_ACCOUNT_PROVIDER, config = accountProviders[id];
  const hud = process.env.TOKENHUD_HUD_DIR || join(homedir(), '.claude', 'hud');
  const cache = process.env.TOKENHUD_CACHE_FILE || process.env.USAGE_CACHE_FILE || join(hud, `.${id}-usage-cache.json`);
  const secrets = [];
  const emit = value => {
    const text = JSON.stringify(value, (_key, item) => typeof item === 'string'
      ? secrets.filter(Boolean).reduce((s, secret) => s.split(secret).join('[redacted]'), item) : item);
    if (process.env.TOKENHUD_STDOUT_ONLY === '1') process.stdout.write(text + '\n');
    else { mkdirSync(dirname(cache), { recursive: true }); writeFileSync(cache, text); }
  };
  const fail = code => emit({ error: code, stale: true, lastAttemptAt: Date.now(), ttlMs: 60_000,
    message: ({ 'no-auth': '请选择此账号有效的 Auth 导出文件；授权过期请由原客户端更新。', region: '此授权地域不匹配或尚未支持该地域的额度接口。',
      parse: '服务端没有返回可识别的数值额度，当前用量未知。', auth: '授权无效或无额度接口权限，请由原客户端更新授权。', 'no-query': '此类型仅支持 Auth 文件额度查询。' })[code] || '额度查询暂不可用。' });
  try {
    if (!config) throw new Error('no-query');
    const snapshot = process.env.TOKENHUD_AUTH_FILE ? readJSON(process.env.TOKENHUD_AUTH_FILE) : null;
    if (snapshot?.authMode && snapshot.authMode !== 'auth') throw new Error('no-query');
    const key = clean(snapshot?.queryKey), context = snapshot?.tokenhudAuthContext ?? {};
    if (!key) throw new Error('no-auth');
    secrets.push(key);
    if (!record(context) || Object.values(context).some(v => typeof v !== 'string' || /[\x00-\x1f\x7f]/.test(v))) throw new Error('no-auth');
    if (context.sourceProvider && context.sourceProvider !== config.source) throw new Error('region');
    const expiry = timestamp(context.expiresAt);
    if (expiry !== null && expiry <= Date.now() / 1000) throw new Error('auth');
    const deadline = Date.now() + 18_000;
    const allowed = new Set([new URL(config.host).origin, ...(config.platform ? [new URL(config.platform).origin] : [])]);
    const request = ({ url, method = 'GET', headers = {}, body, publicRequest = false }, token = key) => {
      const target = new URL(url);
      if (target.protocol !== 'https:' || !allowed.has(target.origin) || target.username || target.password) throw new Error('region');
      const remaining = Math.min(6, (deadline - Date.now()) / 1000);
      if (remaining <= 0) throw new Error('network');
      const combined = { Accept: 'application/json', 'Content-Type': 'application/json', ...(!publicRequest ? { Authorization: `Bearer ${token}` } : {}), ...headers };
      if (Object.values(combined).some(v => !clean(v))) throw new Error('no-auth');
      const args = ['-q', '-sS', '--connect-timeout', String(Math.min(3, remaining)), '--max-time', String(remaining), '--proto', '=https', '-X', method,
        ...Object.entries(combined).flatMap(([k, v]) => ['-H', `${k}: ${v}`]),
        ...(body !== undefined ? ['--data-binary', JSON.stringify(body)] : []), '-w', '\n%{http_code}', '--url', target.toString()];
      const result = spawnSync(process.env.TOKENHUD_CURL || '/usr/bin/curl', args, { encoding: 'utf8', timeout: Math.ceil(remaining * 1000) + 200,
        killSignal: 'SIGKILL', maxBuffer: 2_000_000, stdio: ['ignore', 'pipe', 'pipe'] });
      if (result.error || result.status !== 0) throw new Error('network');
      const split = result.stdout.lastIndexOf('\n'), status = Number(result.stdout.slice(split + 1).trim());
      if (status === 401 || status === 403) throw new Error('auth');
      if (status === 429) throw new Error('ratelimit');
      if (split < 0 || !Number.isInteger(status) || status < 200 || status >= 300) throw new Error('network');
      let data;
      try { data = JSON.parse(result.stdout.slice(0, split)); } catch { throw new Error('parse'); }
      if (!record(data)) throw new Error('parse');
      if (data.statusInfo?.code === 1000048) throw new Error('auth');
      if (data.error || data.statusInfo?.code && data.statusInfo.code !== 0 || data.base_resp?.status_code && data.base_resp.status_code !== 0) throw new Error('api');
      return data;
    };
    let usage;
    if (id === 'qoder' || id === 'qoder-cn') {
      if (context.region && context.region !== config.region) throw new Error('region');
      let token = key;
      if (key.startsWith('pt-')) {
        const job = request({ url: `${config.host}/api/v1/jobToken/exchange`, method: 'POST', publicRequest: true, body: { personal_token: key },
          headers: { 'User-Agent': 'qodercli/1.0.0', 'Cosy-Version': '1.0.0', 'Cosy-ClientType': '5' } });
        token = clean(job.token);
        if (!token) throw new Error('parse');
        secrets.push(token);
      }
      usage = parseQoder(request({ url: `${config.host}/api/v2/quota/usage` }, token));
    } else if (id === 'kiro') {
      // SSO registration region is credential metadata; quota API stays fixed in us-east-1.
      const method = clean(context.authMethod);
      if (!['builder-id', 'idc', 'google', 'github', 'api_key', 'external_idp'].includes(method)) throw new Error('no-auth');
      const profile = clean(context.profileArn);
      if (profile && !/^arn:aws:codewhisperer:us-east-1:\d{12}:profile\/[\w-]+$/.test(profile)) throw new Error('region');
      usage = parseKiro(request({ url: config.host, method: 'POST', headers: {
        'Content-Type': 'application/x-amz-json-1.0', 'x-amz-target': 'AmazonCodeWhispererService.GetUsageLimits',
        ...(method === 'api_key' ? { tokentype: 'API_KEY' } : method === 'external_idp' ? { TokenType: 'EXTERNAL_IDP' } : {}) },
        body: { origin: 'AI_EDITOR', ...(profile ? { profileArn: profile } : {}), resourceType: 'AGENTIC_REQUEST' } }));
    } else if (id === 'zed') {
      const userId = clean(context.userId);
      if (!userId || /\s/.test(userId) || /\s/.test(key)) throw new Error('no-auth');
      usage = parseZed(request({ url: `${config.host}/client/users/me`, headers: { Authorization: `${userId} ${key}`,
        ...(clean(context.systemId) ? { 'x-zed-system-id': clean(context.systemId) } : {}) } }));
    } else {
      const account = (path, userId, body) => request(signedMiniMaxRequest(config, path, key, userId, body));
      let userId = clean(context.realUserID);
      if (!userId) {
        const data = account('/v1/api/user/info');
        const user = data.data?.userInfo ?? data.data?.user_info ?? data.userInfo ?? data.user_info;
        userId = clean(user?.realUserID ?? user?.real_user_id);
        if (!userId) throw new Error('parse');
      }
      let workspaces, partial = false;
      const softFailure = error => { if (error.message === 'auth') throw error; partial = true; };
      try { workspaces = account('/matrix/api/v1/user/get_user_extra_info', userId, {}); }
      catch (error) { softFailure(error); }
      const rows = workspaces?.workspaces ?? workspaces?.data?.workspaces;
      const workspace = (Array.isArray(rows) ? rows : []).find(w => number(w?.workspace_type) === 0 &&
        (typeof w.workspace_id === 'string' || typeof w.workspace_id === 'number'));
      let detail = {};
      try {
        const reply = account('/matrix/api/v1/commerce/get_membership_info', userId, workspace ? { workspace_id: workspace.workspace_id } : {});
        detail = record(reply.data) ? reply.data : reply;
      } catch (error) {
        softFailure(error);
        if (!workspace) throw error;
      }
      const info = { ...(workspace || {}), ...detail,
        op_credit_summary: { ...(workspace?.op_credit_summary || {}), ...(detail.op_credit_summary || {}) },
        ...(workspace?.has_token_plan === true || detail.has_token_plan === true ? { has_token_plan: true } : {}) };
      const m = membership(info);
      let plan;
      if (m.hasPlan === true && m.group) {
        try {
          plan = request({ url: `${config.platform}/v1/api/openplatform/coding_plan/remains`, headers: { 'X-Group-Id': m.group } });
          if (!Array.isArray(plan.model_remains)) throw new Error('parse');
        } catch (error) { softFailure(error); }
      }
      usage = parseMiniMaxCode(info, plan);
      if (usage && partial) { usage.partial = true; usage.message = '已更新可用的额度数据，部分套餐信息或窗口暂不可查询。'; }
    }
    if (!usage) throw new Error('parse');
    emit({ ...usage, generatedAt: Date.now(), ttlMs: 60_000, error: null, stale: false });
  } catch (error) { fail(['no-auth', 'auth', 'region', 'parse', 'api', 'network', 'ratelimit', 'no-query'].includes(error.message) ? error.message : 'parse'); }
}
if (process.argv[1] && realpathSync(resolve(process.argv[1])) === realpathSync(fileURLToPath(import.meta.url))) main();
