// Shared normalization of the documented UsageCache response contract.
export const record = value => value && typeof value === 'object' && !Array.isArray(value) ? value : null;
export const number = value => {
  if (value == null || value === '' || typeof value === 'boolean') return null;
  const parsed = typeof value === 'string' ? Number(value) : value;
  return typeof parsed === 'number' && Number.isFinite(parsed) ? parsed : null;
};
export function epochSeconds(value) {
  if (value == null || value === '') return null;
  const numeric = number(value);
  if (numeric != null) return numeric > 0 ? Math.floor(numeric >= 1e12 ? numeric / 1000 : numeric) : null;
  const time = typeof value === 'string' ? Date.parse(value) : NaN;
  return Number.isFinite(time) ? Math.floor(time / 1000) : null;
}
function windowBucket(value) {
  const raw = record(value);
  if (!raw) return null;
  const bucket = {};
  for (const key of ['used_percentage', 'remaining_percentage', 'amount', 'limit']) {
    const val = number(raw[key]);
    if (val != null) bucket[key] = val;
  }
  if (!Object.keys(bucket).length) return null;
  bucket.resets_at = epochSeconds(raw.resets_at ?? raw.resetsAt);
  for (const key of ['label', 'unit', 'period']) {
    if (typeof raw[key] === 'string' && raw[key]) bucket[key] = raw[key];
  }
  return bucket;
}
export function normalizeUsage(value) {
  const outer = record(value);
  const raw = record(outer?.data) || outer;
  if (!raw) return null;
  const result = {};
  for (const [key, aliases] of Object.entries({
    five_hour: ['five_hour', 'fiveHour', '5h'],
    seven_day: ['seven_day', 'sevenDay', 'week', 'weekly'],
    monthly: ['monthly', 'month'],
  })) {
    const bucket = aliases.map(alias => windowBucket(raw[alias])).find(Boolean);
    if (!bucket) continue;
    let used = bucket.used_percentage;
    if (used == null && bucket.remaining_percentage != null) used = 100 - bucket.remaining_percentage;
    if (used != null) result[key] = { used_percentage: used, resets_at: bucket.resets_at };
  }
  if (Array.isArray(raw.windows)) result.windows = raw.windows.map(windowBucket).filter(Boolean);
  if (!result.five_hour && !result.seven_day && !result.monthly && !result.windows?.length) return null;
  return result;
}
