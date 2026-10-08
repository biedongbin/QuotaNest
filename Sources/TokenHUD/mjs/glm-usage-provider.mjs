#!/usr/bin/env node
// GLM 限额 provider：读 .glm-usage-auth.json → fetch → 提取 → 写 .glm-usage-cache.json
// 由 statusline.mjs fire-and-forget 触发；也可手动 `node glm-usage-provider.mjs` 调试
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const HUD_DIR = join(CLAUDE_DIR, 'hud');
const NAME = process.env.USAGE_PROVIDER_NAME || 'glm';
const AUTH_FILE = process.env.USAGE_AUTH_FILE || join(HUD_DIR, `.${NAME}-usage-auth.json`);
const CACHE_FILE = process.env.USAGE_CACHE_FILE || join(HUD_DIR, `.${NAME}-usage-cache.json`);
const TTL_MS = 60_000;
const FETCH_TIMEOUT_MS = 8000;
const verbose = !!(process.env.USAGE_VERBOSE || process.env.GLM_PROVIDER_VERBOSE);

const readJson = (p, def) => {
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return def; }
};

const writeCache = (obj) => {
  try {
    mkdirSync(HUD_DIR, { recursive: true });
    writeFileSync(CACHE_FILE, JSON.stringify(obj, null, 2));
  } catch { /* best-effort */ }
};

const getByPath = (obj, path) =>
  !path ? undefined : path.split('.').reduce((o, k) => (o == null ? o : o[k]), obj);

const findLimit = (limits, cfg) => {
  if (limits == null) return null;
  const match = cfg?.match ?? cfg; // GLM 用 cfg.match；Ollama 用 cfg 本身(含 mapKey)
  if (match?.mapKey != null && !Array.isArray(limits)) {
    return limits[match.mapKey] ?? null; // map 键名查找：{ "Session (5h)": {...}, ... }
  }
  const arr = Array.isArray(limits) ? limits : [limits];
  if (!match) return arr[0] || null;
  const entries = Object.entries(match);
  return arr.find((l) => entries.every(([k, v]) => l[k] === v)) || null;
};

const extractBucket = (limit, cfg) => {
  if (!limit || !cfg) return null;
  let pct = getByPath(limit, cfg.percentField);
  // 剩余百分比换算：{remainingPercentage:97} → 已用3%
  if (pct == null && cfg.remainingField != null) {
    const rem = getByPath(limit, cfg.remainingField);
    if (typeof rem === 'number') pct = 100 - rem;
  }
  // GPT 等：无现成百分比，用 used/total 算
  if (pct == null && cfg.usedField != null && cfg.totalField != null) {
    const used = getByPath(limit, cfg.usedField);
    const total = getByPath(limit, cfg.totalField);
    if (typeof used === 'number' && typeof total === 'number' && total > 0) {
      pct = (used / total) * 100;
    }
  }
  // Ollama Cloud 原生：usage 是已用小数(0~1)，如 0.111 → 11.1%
  if (pct == null && cfg.usageField != null) {
    const u = getByPath(limit, cfg.usageField);
    if (typeof u === 'number') pct = u * 100;
  }
  if (pct == null) return null;
  const resetsRaw = getByPath(limit, cfg.resetsAtField);
  let resetsAt = null;
  if (typeof resetsRaw === 'number') {
    resetsAt = cfg.resetsAtUnit === 'ms' ? Math.floor(resetsRaw / 1000) : resetsRaw;
  } else if (typeof resetsRaw === 'string' && resetsRaw) {
    const t = Date.parse(resetsRaw); // ISO 8601 → epoch ms
    if (!Number.isNaN(t)) resetsAt = Math.floor(t / 1000);
  }
  // 固定周期重置：resetsAtWeekly → 下周一 0 点 (本地时区) epoch 秒
  if (resetsAt == null && cfg.resetsAtWeekly) {
    resetsAt = nextMondayMidnight();
  }
  // 固定每日时刻重置：resetsAtDaily → 今天/明天 HH:MM (本地时区) epoch 秒
  if (resetsAt == null && cfg.resetsAtDaily != null) {
    resetsAt = nextDailyTime(cfg.resetsAtDaily);
  }
  // 多个固定时刻重置：resetsAtTimes → 取最近的下一个 (今天或明天)
  if (resetsAt == null && Array.isArray(cfg.resetsAtTimes)) {
    resetsAt = nextOfTimes(cfg.resetsAtTimes);
  }
  return { used_percentage: pct, resets_at: resetsAt };
};

// 下周一 0 点 (本地时区) 的 epoch 秒; 今天周一则取下周一
function nextMondayMidnight() {
  const now = new Date();
  const day = now.getDay(); // 0=周日, 1=周一
  let daysAhead = (8 - day) % 7; // 周一=1 → 7天后; 周日=0 → 1天后
  if (daysAhead === 0) daysAhead = 7; // 今天周一 → 下周一
  const next = new Date(now.getFullYear(), now.getMonth(), now.getDate() + daysAhead, 0, 0, 0, 0);
  return Math.floor(next.getTime() / 1000);
}

// 每天固定时刻 (HH:MM, 本地时区) 的 epoch 秒; 已过则取明天
function nextDailyTime(hhmm) {
  const [h, m] = String(hhmm).split(':').map(Number);
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate(), h, m, 0, 0);
  if (today.getTime() <= now.getTime()) today.setDate(today.getDate() + 1);
  return Math.floor(today.getTime() / 1000);
}

// 多个固定时刻 (HH:MM 数组) 中最近的下一个; 今天已过则取明天
function nextOfTimes(times) {
  const now = new Date();
  const nowMs = now.getTime();
  let best = null;
  for (const t of times) {
    const [h, m] = String(t).split(':').map(Number);
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate(), h, m, 0, 0);
    let ms = today.getTime();
    if (ms <= nowMs) ms += 24 * 3600 * 1000; // 今天已过 → 明天
    if (best == null || ms < best) best = ms;
  }
  return best == null ? null : Math.floor(best / 1000);
}

async function main() {
  const auth = readJson(AUTH_FILE, null);
  if (!auth || !auth.apiUrl) {
    writeCache({ error: 'no-auth', generatedAt: Date.now(), ttlMs: TTL_MS });
    if (verbose) console.error(`[${NAME}-provider] missing auth file`);
    return;
  }

  // 保留上一次值（含上次 error 时的旧桶），出错时作 stale 返回，不清空 UI
  const prev = readJson(CACHE_FILE, null);
  const prevBuckets = prev
    ? { five_hour: prev.five_hour, seven_day: prev.seven_day }
    : {};

  // 用 curl 而非 node fetch：bigmodel 对 node/undici 客户端风控（返回 code:401），
  // curl 的 UA + TLS 指纹被放行。header 从 auth.headers 动态构造。
  const headerArgs = Object.entries(auth.headers || {}).flatMap(([k, v]) => ['-H', `${k}: ${v}`]);
  const method = (auth.method || 'GET').toUpperCase();
  const methodArgs = method === 'GET' ? [] : ['-X', method];
  const r = spawnSync('curl', [
    '-s', '--max-time', String(Math.ceil(FETCH_TIMEOUT_MS / 1000)),
    ...methodArgs, auth.apiUrl, ...headerArgs,
  ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

  if (r.error || (r.status !== 0 && !r.stdout)) {
    writeCache({ ...prevBuckets, error: 'network', generatedAt: Date.now(), ttlMs: TTL_MS, stale: true });
    if (verbose) console.error(`[${NAME}-provider] curl failed:`, r.error?.message || ('exit ' + r.status));
    return;
  }
  let data;
  try { data = JSON.parse(r.stdout); }
  catch {
    writeCache({ ...prevBuckets, error: 'parse', generatedAt: Date.now(), ttlMs: TTL_MS, stale: true });
    if (verbose) console.error(`[${NAME}-provider] parse failed:`, (r.stdout || '').slice(0, 200));
    return;
  }

  if (process.env.USAGE_DEBUG) {
    try { mkdirSync(HUD_DIR, { recursive: true }); writeFileSync(join(HUD_DIR, `.${NAME}-usage-raw.json`), JSON.stringify(data, null, 2)); } catch {}
  }

  // 认证失败检测：GLM 用 body.code===401；GPT 用 {error:"Unauthorized"}（均 HTTP 200）
  const errVal = auth.errorField ? getByPath(data, auth.errorField) : undefined;
  if (errVal != null && (auth.authFailValues || ['Unauthorized']).includes(errVal)) {
    writeCache({ ...prevBuckets, error: 'auth', generatedAt: Date.now(), ttlMs: TTL_MS, stale: true });
    if (verbose) console.error(`[${NAME}-provider] auth expired (${auth.errorField}=${errVal})`);
    return;
  }
  const code = getByPath(data, auth.codeField || 'code');
  if (code === (auth.authFailCode ?? 401)) {
    writeCache({ ...prevBuckets, error: 'auth', generatedAt: Date.now(), ttlMs: TTL_MS, stale: true });
    if (verbose) console.error(`[${NAME}-provider] auth expired (body code=${code})`);
    return;
  }
  if (auth.successCode != null && code !== auth.successCode) {
    writeCache({ ...prevBuckets, error: 'api:' + code, generatedAt: Date.now(), ttlMs: TTL_MS, stale: true });
    if (verbose) console.error(`[${NAME}-provider] api code=`, code);
    return;
  }

  const limits = getByPath(data, auth.limitsArrayPath || 'data.limits') || [];
  const fiveHour = extractBucket(findLimit(limits, auth.five_hour), auth.five_hour);
  const sevenDay = extractBucket(findLimit(limits, auth.seven_day), auth.seven_day);

  writeCache({
    generatedAt: Date.now(),
    ttlMs: TTL_MS,
    five_hour: fiveHour,
    seven_day: sevenDay,
    error: null,
    stale: false,
  });

  if (verbose) {
    console.error(`[${NAME}-provider] ok`, JSON.stringify({ five_hour: fiveHour, seven_day: sevenDay }));
  }
}

main().catch(() => writeCache({ error: 'fatal', generatedAt: Date.now(), ttlMs: TTL_MS }));
