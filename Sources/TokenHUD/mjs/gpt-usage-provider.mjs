#!/usr/bin/env node
// GPT (ChatGPT/Codex) 用量 provider: 直查官方 GET /backend-api/wham/usage
// 认证: 只读 ${CODEX_HOME:-~/.codex}/auth.json (auth pointers via codexAuthFile),
// 不写回不刷新 (Codex CLI 管 refresh_token 轮换, 双写者会触发 reuse 作废家族)
// 容器兼容集取自 9router open-sse/services/usage/codex.js (MIT): rate_limit
// 为主，兼容 rate_limits / rate_limits_by_limit_id；主次是窗口角色，不代表周期。
// 周期仅按官方 limit_window_seconds，已知 5h/7天投影旧桶，其余保留动态窗口。
// used_percent|percent_used；reset_at|resets_at|resetAt（秒/毫秒）与相对秒兜底。
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const HUD_DIR = process.env.TOKENHUD_HUD_DIR || join(CLAUDE_DIR, 'hud');
const AUTH_FILE = process.env.TOKENHUD_AUTH_FILE || process.env.USAGE_AUTH_FILE || join(HUD_DIR, '.gpt-usage-auth.json');
const CACHE_FILE = process.env.TOKENHUD_CACHE_FILE || process.env.USAGE_CACHE_FILE || join(HUD_DIR, '.gpt-usage-cache.json');
const USAGE_URL = 'https://chatgpt.com/backend-api/wham/usage';
const TIMEOUT_S = 12;
const TTL_MS = 60_000;
const verbose = !!process.env.USAGE_VERBOSE;
// 测试注入口: 正常路径恒为 /usr/bin/curl
const CURL = process.env.TOKENHUD_CURL || '/usr/bin/curl';

const readJson = (p) => {
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; }
};
const writeCache = (obj) => {
  if (process.env.TOKENHUD_STDOUT_ONLY === '1') {
    process.stdout.write(JSON.stringify(obj) + '\n');
    return;
  }
  try { mkdirSync(HUD_DIR, { recursive: true }); writeFileSync(CACHE_FILE, JSON.stringify(obj, null, 2)); } catch {}
};
// 失败通用出口：同账号旧缓存有 legacy 桶或有效动态窗口则保留，否则写错误态。
// (防账号切换后沿用上一账号的额度)
// generatedAt = 最近成功快照时间: 失败不推进, 只前移 lastAttemptAt (FR-03.8)
const writeFailure = (kind, detail, accountId) => {
  const prev = readJson(CACHE_FILE);
  const sameAccount = prev && (prev.account_id ?? null) === (accountId ?? null);
  const now = Date.now();
  const hasWindows = Array.isArray(prev?.windows)
    && prev.windows.some(w => num(w?.used_percentage) != null);
  if (sameAccount && (prev.five_hour || prev.seven_day || prev.monthly || hasWindows)) {
    writeCache({ ...prev, error: kind, stale: true, lastAttemptAt: now });
  } else {
    writeCache({ error: kind, lastAttemptAt: now, ttlMs: TTL_MS, stale: true });
  }
  if (verbose) console.error(`[gpt-provider] ${kind}: ${detail}`);
};

// ---------- 认证: 只读本机 Codex 登录 ----------
function codexAuth() {
  const pointer = readJson(AUTH_FILE) || {};
  const authPath = (typeof pointer.codexAuthFile === 'string' && pointer.codexAuthFile.startsWith('/'))
    ? pointer.codexAuthFile
    : join(process.env.CODEX_HOME || join(homedir(), '.codex'), 'auth.json');
  const auth = readJson(authPath);
  if (!auth || auth.auth_mode !== 'chatgpt' || !auth.tokens?.access_token) return null;
  return { accessToken: auth.tokens.access_token, accountId: auth.tokens.account_id || null };
}

// ---------- 解析 (兼容集同 9router) ----------
const num = (v) => {
  const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v;
  return typeof n === 'number' && Number.isFinite(n) ? n : null;
};
const rec = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : null);

function resetEpochSec(w) {
  // 数值 (秒/毫秒, <1e12 判定); 纯数字串同规则; 其他字符串按 ISO 日期
  const raw = w.reset_at ?? w.resets_at ?? w.resetAt;
  if (raw != null && raw !== '') {
    if (typeof raw === 'number' || /^\d+$/.test(String(raw))) {
      const n = Number(raw);
      if (n > 0) return n < 1e12 ? Math.floor(n) : Math.floor(n / 1000);
    } else {
      const t = Date.parse(String(raw));
      if (Number.isFinite(t) && t > 0) return Math.floor(t / 1000);
    }
  }
  const rel = num(w.reset_after_seconds ?? w.resetAfterSeconds);
  if (rel && rel > 0) return Math.floor(Date.now() / 1000 + rel);
  return null;
}

// used_percent 缺失/非法 → null (不伪造 0%)
function windowBucket(w) {
  const obj = rec(w);
  if (!obj) return null;
  const used = num(obj.used_percent ?? obj.percent_used);
  if (used == null) return null;
  return {
    used_percentage: Math.round(Math.max(0, Math.min(100, used)) * 10) / 10,
    resets_at: resetEpochSec(obj),
  };
}

function windowPeriod(w) {
  const seconds = num(w.limit_window_seconds);
  if (seconds == null || seconds <= 0) return { label: null, period: '周期未知', legacy: null };
  if (seconds === 18000) return { label: '5小时', period: '5小时', legacy: 'five_hour' };
  if (seconds === 604800) return { label: '本周', period: '7天', legacy: 'seven_day' };
  const period = seconds % 3600 === 0 ? `${seconds / 3600}小时`
    : seconds % 60 === 0 ? `${seconds / 60}分钟` : `${seconds}秒`;
  return { label: period, period, legacy: null };
}

// 别名只取一个有效对象；周期判断与主次角色分离，不从重置倒计时推断。
function pickWindow(rl, names, role) {
  for (const name of names) {
    const raw = rec(rl[name]);
    const bucket = windowBucket(raw);
    if (bucket) return { role, bucket, ...windowPeriod(raw) };
  }
  return null;
}

function rateLimitGroups(data) {
  const groups = [];
  const hasWindow = limits => rec(limits) && ['primary_window', 'primary', 'secondary_window', 'secondary']
    .some(key => windowBucket(limits[key]));
  const byId = rec(data.rate_limits_by_limit_id) || {};
  const primary = [data.rate_limit, data.rate_limits, byId.codex].find(hasWindow);
  if (primary) groups.push({ id: 'codex', name: null, limits: primary, main: true });
  const seen = new Set(primary ? ['codex'] : []);
  const text = v => typeof v === 'string' && v.trim() !== '' ? v.trim() : null;
  for (const extra of Array.isArray(data.additional_rate_limits) ? data.additional_rate_limits : []) {
    const limits = [extra?.rate_limit, extra?.rate_limits].find(hasWindow);
    const id = text(extra?.metered_feature) || text(extra?.limit_name);
    if (!limits || !id || seen.has(id)) continue;
    groups.push({ id, name: text(extra.limit_name) || id, limits, main: false });
    seen.add(id);
  }
  for (const [id, limits] of Object.entries(byId)) {
    if (!id.trim() || !hasWindow(limits) || seen.has(id)) continue;
    groups.push({ id, name: id, limits, main: false });
    seen.add(id);
  }
  // 同名的不同模型限制保留各自身份，不能合并为一个额度。
  const names = groups.map(group => group.name);
  for (const group of groups) {
    if (group.name && names.filter(name => name === group.name).length > 1) {
      group.name = `${group.name} (${group.id})`;
    }
  }
  return groups;
}

function usageWindows(data) {
  const windows = [];
  const legacy = { five_hour: null, seven_day: null };
  for (const group of rateLimitGroups(data)) {
    const parsed = [
      pickWindow(group.limits, ['primary_window', 'primary'], '主额度窗口'),
      pickWindow(group.limits, ['secondary_window', 'secondary'], '次额度窗口'),
    ].filter(Boolean);
    for (const window of parsed) {
      const samePeriod = parsed.filter(other => other.period === window.period);
      let label = window.label || window.role;
      if (window.label && samePeriod.length > 1) label = `${window.role} · ${label}`;
      if (group.name) label = `${group.name} · ${label}`;
      windows.push({ label, period: window.period, ...window.bucket });
      // 旧 HUD 只能表达单一主额度桶；附加模型或歧义周期不可覆盖它。
      if (group.main && window.legacy && samePeriod.length === 1) {
        legacy[window.legacy] = window.bucket;
      }
    }
  }
  return { windows, ...legacy };
}

// ---------- 主流程 ----------
function main() {
  const cred = codexAuth();
  if (!cred) {
    writeFailure('no-auth', '本机无 ChatGPT 登录 (未找到 ~/.codex/auth.json 或 auth_mode != chatgpt); 请 codex login');
    return;
  }
  const args = [
    '-sS', '--connect-timeout', '8', '--max-time', String(TIMEOUT_S),
    '-H', `Authorization: Bearer ${cred.accessToken}`,
    '-H', 'Accept: application/json',
    '-w', '\n%{http_code}',
  ];
  if (cred.accountId) args.push('-H', `chatgpt-account-id: ${cred.accountId}`);
  args.push(USAGE_URL);
  const r = spawnSync(CURL, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

  if (r.error || r.status !== 0) {
      writeFailure('network', r.error?.message || `exit ${r.status}`, cred.accountId);
    return;
  }
  // 拆 HTTP 状态与体 (-w 附加; 容忍尾部空白/换行)
  const out = r.stdout.trimEnd();
  const sep = out.lastIndexOf('\n');
  const status = parseInt(out.slice(sep + 1).trim(), 10);
  const body = out.slice(0, sep);
  if (status === 401 || status === 403) {
    writeFailure('auth', `HTTP ${status}: Codex 登录已过期, 请 codex login`, cred.accountId);
    return;
  }
  if (status === 429) {
      writeFailure('ratelimit', `HTTP 429`, cred.accountId);
    return;
  }
  if (status !== 200) {
      writeFailure('network', `HTTP ${status}: ${body.slice(0, 80)}`, cred.accountId);
    return;
  }
  let data;
  try { data = JSON.parse(body); } catch {
    writeFailure('parse', 'non-JSON: ' + body.slice(0, 80), cred.accountId);
    return;
  }
  const { windows, five_hour, seven_day } = usageWindows(rec(data) || {});
  if (!windows.length) {
    writeFailure('parse', '无有效窗口字段: ' + body.slice(0, 80), cred.accountId);
    return;
  }
  writeCache({
    account_id: cred.accountId,
    five_hour,
    seven_day,
    monthly: null,
    windows,
    generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false,
  });
  if (verbose) console.error('[gpt-provider] ok');
}

main();
