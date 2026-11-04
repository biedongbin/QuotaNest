// Provider wire facts: CPA Management-Center quota providers/builders, Magpie
// subscription_usage.go/google.go, and 9router services/usage. Independent parsers.
export const number = value => {
  if (!['number', 'string'].includes(typeof value) || (typeof value === 'string' && !value.trim())) return null;
  const result = Number(value);
  return Number.isFinite(result) ? result : null;
};
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
export const instant = value => {
  const n = number(value);
  if (n !== null) return n > 0 ? (n < 1e11 ? n : n / 1000) : null;
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}(?:T|$)/.test(value)) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) && ms > 0 ? ms / 1000 : null;
};
const percent = value => { const n = number(value); return n !== null && n >= 0 && n <= 100 ? n : null; };
const fractionUsed = value => { const n = number(value); return n !== null && n >= 0 && n <= 1 ? (1 - n) * 100 : null; };
const duration = (start, end) => {
  const a = instant(start), b = instant(end);
  if (a === null || b === null || b <= a) return undefined;
  const seconds = b - a;
  if (seconds % 86400 === 0) return `${seconds / 86400}天`;
  if (seconds % 3600 === 0) return `${seconds / 3600}小时`;
  return `${seconds}秒`;
};
const window = (label, fields, reset, period) => ({ label, ...fields,
  ...(instant(reset) !== null ? { resets_at: instant(reset) } : {}), ...(period ? { period } : {}) });
const observed = w => ['used_percentage', 'amount', 'limit', 'resets_at'].some(k => w[k] !== undefined);
const add = (windows, w) => { if (observed(w)) windows.push(w); };
function claude(data) {
  const windows = [];
  for (const [key, value] of Object.entries(data)) {
    if (!record(value) || ['extra_usage'].includes(key)) continue;
    if (key === 'five_hour' || key === 'seven_day' || key.startsWith('seven_day_') || key === 'iguana_necktie') {
      const used = percent(value.utilization);
      add(windows, window(key, used === null ? {} : { used_percentage: used }, value.resets_at, key === 'five_hour' ? '5小时' : key.startsWith('seven_day') ? '7天' : undefined));
    }
    const limit = number(value.limit_dollars), amount = number(value.used_dollars);
    if (limit !== null || amount !== null) add(windows, window(key, {
      unit: 'USD', ...(limit !== null ? { limit } : {}), ...(amount !== null ? { amount } : {}),
      ...(percent(value.utilization) !== null ? { used_percentage: percent(value.utilization) } : {}),
    }, value.resets_at));
  }
  for (const value of Array.isArray(data.limits) ? data.limits : []) {
    if (value?.kind !== 'weekly_scoped') continue;
    const used = percent(value.percent);
    add(windows, window(value.scope?.model?.display_name || 'weekly_scoped', used === null ? {} : { used_percentage: used }, value.resets_at, '7天'));
  }
  const extra = data.extra_usage;
  if (record(extra) && extra.is_enabled !== false) {
    const amount = number(extra.used_credits), limit = number(extra.monthly_limit), used = percent(extra.utilization);
    add(windows, window('extra_usage', { unit: typeof extra.currency === 'string' ? extra.currency : 'credits',
      ...(amount !== null ? { amount } : {}), ...(limit !== null ? { limit } : {}),
      ...(used !== null ? { used_percentage: used } : {}),
    }, extra.resets_at, '月'));
  }
  return windows;
}
function antigravity(data) {
  const windows = [];
  const groups = data.groups ?? data.quotaSummary?.groups ?? data.quota_summary?.groups;
  for (const group of Array.isArray(groups) ? groups : []) {
    for (const bucket of Array.isArray(group?.buckets) ? group.buckets : []) {
      if (!record(bucket) || bucket.disabled === true) continue;
      const used = fractionUsed(bucket.remainingFraction ?? bucket.remaining_fraction);
      const raw = bucket.window;
      const period = ({ '5h': '5小时', weekly: '7天' })[raw] ?? (typeof raw === 'string' ? raw : undefined);
      add(windows, window([group.displayName ?? group.display_name, bucket.displayName ?? bucket.display_name ?? bucket.bucketId ?? bucket.bucket_id, raw].filter(Boolean).join(' · ') || 'quota',
        used === null ? {} : { used_percentage: used }, bucket.resetTime ?? bucket.reset_time, period));
    }
  }
  return windows;
}
function gemini(data) {
  const windows = [];
  for (const bucket of Array.isArray(data.buckets) ? data.buckets : []) {
    if (!record(bucket)) continue;
    const used = fractionUsed(bucket.remainingFraction ?? bucket.remaining_fraction);
    const label = [bucket.modelId ?? bucket.model_id, bucket.tokenType ?? bucket.token_type].filter(Boolean).join(' · ');
    if (!label) continue;
    add(windows, window(label, used === null ? {} : { used_percentage: used }, bucket.resetTime ?? bucket.reset_time));
  }
  return windows;
}
function copilot(data) {
  const windows = [];
  const reset = data.quota_reset_date_utc ?? data.quota_reset_date;
  for (const [key, quota] of Object.entries(record(data.quota_snapshots) ? data.quota_snapshots : {})) {
    if (!record(quota)) continue;
    if (quota.unlimited === true) { windows.push({ label: key, period: '月', unit: 'requests', unlimited: true }); continue; }
    const limit = number(quota.entitlement), remaining = number(quota.quota_remaining ?? quota.remaining);
    const amount = limit !== null && remaining !== null ? Math.max(0, limit - remaining) : null;
    const remPercent = percent(quota.percent_remaining);
    const used = amount !== null && limit > 0 ? amount / limit * 100 : remPercent !== null ? 100 - remPercent : null;
    add(windows, window(key, { unit: 'requests', ...(limit !== null ? { limit } : {}),
      ...(amount !== null ? { amount } : {}), ...(used !== null ? { used_percentage: used } : {}),
    }, quota.quota_reset_at ?? reset, '月'));
  }
  if (!record(data.quota_snapshots)) {
    for (const [key, limitValue] of Object.entries(record(data.monthly_quotas) ? data.monthly_quotas : {})) {
      const limit = number(limitValue), remaining = number(data.limited_user_quotas?.[key]);
      const amount = limit !== null && remaining !== null ? Math.max(0, limit - remaining) : null;
      add(windows, window(key, { unit: 'requests', ...(limit !== null ? { limit } : {}),
        ...(amount !== null ? { amount } : {}), ...(amount !== null && limit > 0 ? { used_percentage: amount / limit * 100 } : {}),
      }, data.limited_user_reset_date, '月'));
    }
  }
  return windows;
}
function devin(data) {
  const windows = [], status = data.userStatus?.planStatus;
  if (!record(status)) return windows;
  for (const [id, period] of [['daily', '1天'], ['weekly', '7天']]) {
    const remaining = percent(status[`${id}QuotaRemainingPercent`]);
    add(windows, window(id, remaining === null ? {} : { used_percentage: 100 - remaining }, status[`${id}QuotaResetAtUnix`], period));
  }
  return windows;
}
function grok(data) {
  const windows = [], config = record(data.config) ? data.config : data;
  const current = config.currentPeriod ?? config.current_period ?? {};
  const start = current.start ?? config.billingPeriodStart ?? config.billing_period_start;
  const end = current.end ?? config.billingPeriodEnd ?? config.billing_period_end;
  const used = percent(config.creditUsagePercent ?? config.credit_usage_percent);
  if (used !== null) add(windows, window('creditUsagePercent', { used_percentage: used, unit: 'credits' }, end, duration(start, end) ?? current.type));
  // productUsage is a breakdown of the same shared pool, not additional allowances.
  // The credits-format endpoint does not establish a currency; retain credits.
  for (const [label, limitValue, amountValue] of [
    ['included', config.monthlyLimit ?? config.monthly_limit, config.includedUsed ?? config.included_used ?? config.totalUsed ?? config.total_used ?? config.used],
    ['onDemand', config.onDemandCap ?? config.on_demand_cap, config.onDemandUsed ?? config.on_demand_used],
  ]) {
    const limit = number(limitValue?.val ?? limitValue), amount = number(amountValue?.val ?? amountValue);
    if (limit === null && amount === null) continue;
    const billingStart = config.billingPeriodStart ?? config.billing_period_start;
    const billingEnd = config.billingPeriodEnd ?? config.billing_period_end;
    add(windows, window(label, { unit: 'credits', ...(limit !== null ? { limit } : {}), ...(amount !== null ? { amount } : {}),
      ...(amount !== null && limit > 0 ? { used_percentage: amount / limit * 100 } : {}),
    }, billingEnd, duration(billingStart, billingEnd)));
  }
  const prepaid = config.prepaidBalance ?? config.prepaid_balance;
  const balance = number(prepaid?.val ?? prepaid);
  if (balance !== null) windows.push({ label: 'prepaidBalance', amount: balance, unit: 'credits', period: 'balance' });
  return windows;
}
const parsers = { 'claude-code': claude, antigravity, 'gemini-cli': gemini, 'github-copilot': copilot, devin, 'grok-cli': grok };
export function parseAuthUsage(provider, data) {
  if (!record(data) || !parsers[provider] || data.error || data.code && data.code !== 0) return null;
  const windows = parsers[provider](data);
  return windows.length ? { windows } : null;
}
