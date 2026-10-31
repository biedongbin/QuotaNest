// Provider web contracts verified against public CodexBar sources at
// 348e2fa8d36ae8e452739ca07a79e83ab9d25e98. Independent implementation;
// see docs/provider-web-query-contracts.md. HTML/Seroval is data, never executable code.
import { epochSeconds, normalizeUsage, number, record } from './usage-normalize.mjs';

function signedOut(text) {
  const page = text.toLowerCase();
  return /<form\b/.test(page) && (/type=["']password["']/.test(page)
    || /(?:action|href)=["'][^"']*(?:signin|sign-in|\/login|\/auth)[^"']*["']/.test(page));
}
function snapshot(windows, legacy = {}) {
  return windows.length ? { ...legacy, windows } : null;
}

export function parseOllamaHTML(html) {
  const page = html.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, '');
  const labels = ['Monthly usage', 'Free usage', 'Session usage', 'Hourly usage', 'Weekly usage'];
  const blocks = [];
  for (const label of labels) {
    const marker = new RegExp('>\\s*' + label + '\\s*<', 'i').exec(page);
    if (!marker) continue;
    const tail = page.slice(marker.index + marker[0].length);
    let end = Math.min(tail.length, 4000);
    for (const next of labels.filter(value => value !== label)) {
      const boundary = new RegExp('>\\s*' + next + '\\s*<', 'i').exec(tail);
      if (boundary) end = Math.min(end, boundary.index);
    }
    const block = tail.slice(0, end);
    let percent = number(/([0-9]+(?:\.[0-9]+)?)\s*%\s*used/i.exec(block)?.[1]);
    let amount = null, limit = null;
    const dollars = /\$([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)\s+of\s+\$([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)\s+used/i.exec(block);
    if (dollars) {
      amount = number(dollars[1].replaceAll(',', ''));
      limit = number(dollars[2].replaceAll(',', ''));
      if (percent == null && amount != null && limit > 0) percent = amount / limit * 100;
    }
    if (percent == null) percent = number(/width\s*:\s*([0-9]+(?:\.[0-9]+)?)%/i.exec(block)?.[1]);
    if (percent == null) continue;
    const resets = /data-time\s*=\s*["']([^"']+)["']/i.exec(block)?.[1];
    blocks.push({ source: label, used_percentage: percent, resets_at: epochSeconds(resets),
      ...(amount != null && limit > 0 ? { amount, limit, unit: 'USD' } : {}) });
  }
  const windows = [], legacy = {};
  const monthly = blocks.find(block => block.source === 'Monthly usage') || blocks.find(block => block.source === 'Free usage');
  const session = blocks.find(block => block.source === 'Session usage') || blocks.find(block => block.source === 'Hourly usage');
  const weekly = blocks.find(block => block.source === 'Weekly usage');
  for (const [block, label, key] of [[monthly, '本月', 'monthly'],
    [session, session?.source === 'Hourly usage' ? '小时额度' : '会话', session?.source === 'Hourly usage' ? null : 'five_hour'],
    [weekly, '本周', 'seven_day']]) {
    if (!block) continue;
    const { source, ...data } = block;
    windows.push({ label, ...data });
    if (key) legacy[key] = { used_percentage: data.used_percentage, resets_at: data.resets_at };
  }
  return snapshot(windows, legacy) || (signedOut(page) ? { error: 'auth' } : null);
}

function resetAt(raw, now) {
  const explicit = epochSeconds(raw.resetsAt ?? raw.resets_at ?? raw.resetAt ?? raw.reset_at);
  if (explicit != null) return explicit;
  const seconds = number(raw.resetInSec ?? raw.resetInSeconds ?? raw.reset_in_sec);
  return seconds != null && seconds >= 0 ? Math.floor(now / 1000 + seconds) : null;
}
function parseMeter(raw, now, label) {
  const meter = record(raw);
  if (!meter) return null;
  let percent = number(meter.usagePercent ?? meter.percent ?? meter.usedPercent ?? meter.percentUsed ?? meter.used_percentage);
  const micros = meter.usedMicroCents != null || meter.limitMicroCents != null;
  const used = number(micros ? meter.usedMicroCents : meter.used);
  const limit = number(micros ? meter.limitMicroCents : (meter.total ?? meter.limit));
  if (percent == null && used != null && limit > 0) percent = used / limit * 100;
  if (percent == null) return null;
  return { label, used_percentage: percent, resets_at: resetAt(meter, now),
    ...(used != null && limit > 0 ? { amount: used / (micros ? 1e8 : 1), limit: limit / (micros ? 1e8 : 1), unit: 'USD' } : {}) };
}
function parseMeters(meters, now, consoleShape = false) {
  const windows = [], legacy = {};
  for (const [aliases, label, key] of [
    [consoleShape ? ['fiveHour'] : ['rollingUsage', 'rolling', 'rolling_usage'], '滚动', 'five_hour'],
    [consoleShape ? ['week'] : ['weeklyUsage', 'weekly', 'weekly_usage'], '本周', 'seven_day'],
    [consoleShape ? ['month'] : ['monthlyUsage', 'monthly', 'monthly_usage'], '本月', 'monthly'],
  ]) {
    const parsed = aliases.map(alias => parseMeter(meters[alias], now, label)).find(Boolean);
    if (!parsed) continue;
    windows.push(parsed);
    legacy[key] = { used_percentage: parsed.used_percentage, resets_at: parsed.resets_at };
  }
  return snapshot(windows, legacy);
}
function parseJSONUsage(raw, now, depth = 0) {
  const root = record(raw);
  if (!root || depth > 3) return null;
  if (root.error) return null;
  if (root.access === null) return { error: 'no-subscription' };
  const meters = record(root.access?.meters);
  if (meters) return parseMeters(meters, now, true);
  const own = normalizeUsage(root) || parseMeters(root, now);
  if (own) return own;
  for (const key of ['data', 'result', 'usage', 'billing', 'payload']) {
    const child = parseJSONUsage(root[key], now, depth + 1);
    if (child) return child;
  }
  return null;
}
export function parseOpenCodeUsage(text, now = Date.now()) {
  try {
    const root = JSON.parse(text);
    if (root === null) return { error: 'no-subscription' };
    return parseJSONUsage(root, now);
  } catch { /* The legacy page embeds shallow Seroval objects, not JSON. */ }
  const windows = [], legacy = {};
  for (const [name, label, key] of [['rollingUsage', '滚动', 'five_hour'],
    ['weeklyUsage', '本周', 'seven_day'], ['monthlyUsage', '本月', 'monthly']]) {
    const object = new RegExp('\\b' + name + '\\s*:\\s*(?:\\$R\\[\\d+\\]\\s*=\\s*)?\\{([^{}]{0,3000})\\}').exec(text)?.[1];
    if (!object) continue;
    const numeric = field => number(new RegExp('\\b' + field + '\\s*:\\s*(-?\\d+(?:\\.\\d+)?)\\b').exec(object)?.[1]);
    const percent = numeric('usagePercent');
    if (percent == null) continue;
    const seconds = numeric('resetInSec');
    const resets = seconds != null && seconds >= 0 ? Math.floor(now / 1000 + seconds) : null;
    const bucket = { used_percentage: percent, resets_at: resets };
    windows.push({ label, ...bucket });
    legacy[key] = bucket;
  }
  return snapshot(windows, legacy) || (signedOut(text) ? { error: 'auth' } : null);
}
export function openCodeWorkspaceIDs(text) {
  try {
    const values = JSON.parse(text);
    if (Array.isArray(values)) return values.map(value => value?.id).filter(validWorkspaceID);
  } catch { /* legacy Seroval workspace list */ }
  return [...text.matchAll(/\bid\s*:\s*["'](wrk_[A-Za-z0-9_-]+)["']/g)].map(match => match[1]);
}
export function validWorkspaceID(value) {
  return typeof value === 'string' && /^(?:wrk_|org_)[A-Za-z0-9_-]+$/.test(value);
}
