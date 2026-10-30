#!/usr/bin/env node
// GPT (ChatGPT/Codex) 用量 provider: 直查官方 GET /backend-api/wham/usage
// 认证: 只读 ${CODEX_HOME:-~/.codex}/auth.json (auth pointers via codexAuthFile),
// 不写回不刷新 (Codex CLI 管 refresh_token 轮换, 双写者会触发 reuse 作废家族)
// 解析兼容集取自 9router open-sse/services/usage/codex.js (MIT): rate_limit
// 为主, 兼容 rate_limits / rate_limits_by_limit_id.codex; primary→5h,
// secondary→周; used_percent|percent_used; reset_at|resets_at|resetAt
// (秒/毫秒 <1e12 判定) 与 reset_after_seconds 相对秒
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const HUD_DIR = join(CLAUDE_DIR, 'hud');
const AUTH_FILE = process.env.USAGE_AUTH_FILE || join(HUD_DIR, '.gpt-usage-auth.json');
const CACHE_FILE = process.env.USAGE_CACHE_FILE || join(HUD_DIR, '.gpt-usage-cache.json');
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
  try { mkdirSync(HUD_DIR, { recursive: true }); writeFileSync(CACHE_FILE, JSON.stringify(obj, null, 2)); } catch {}
};
// 失败通用出口: 旧缓存有桶且同账号则保留 (UI 用上一轮), 否则写错误态
// (防账号切换后沿用上一账号的额度)
// generatedAt = 最近成功快照时间: 失败不推进, 只前移 lastAttemptAt (FR-03.8)
const writeFailure = (kind, detail, accountId) => {
  const prev = readJson(CACHE_FILE);
  const sameAccount = prev && (prev.account_id ?? null) === (accountId ?? null);
  const now = Date.now();
  if (sameAccount && (prev.five_hour || prev.seven_day || prev.monthly)) {
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

// rate_limit 为主, 兼容 rate_limits / rate_limits_by_limit_id.codex
function rateLimitBody(data) {
  return rec(data.rate_limit) || rec(data.rate_limits)
    || rec(rec(data.rate_limits_by_limit_id)?.codex) || {};
}
const pickWindow = (rl, names) => {
  for (const n of names) {
    const b = windowBucket(rl[n]);
    if (b) return b;
  }
  return null;
};

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
  const rl = rateLimitBody(data);
  const fiveHour = pickWindow(rl, ['primary_window', 'primary']);
  const sevenDay = pickWindow(rl, ['secondary_window', 'secondary']);
  if (!fiveHour && !sevenDay) {
    writeFailure('parse', '无有效窗口字段: ' + body.slice(0, 80), cred.accountId);
    return;
  }
  // P1-11 动态窗口: 旧桶投影 (5小时/本周)
  const windows = [
    fiveHour && { label: '5小时', ...fiveHour },
    sevenDay && { label: '本周', ...sevenDay },
  ].filter(Boolean);
  writeCache({
    account_id: cred.accountId,
    five_hour: fiveHour,
    seven_day: sevenDay,
    monthly: null,
    windows,
    generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false,
  });
  if (verbose) console.error('[gpt-provider] ok');
}

main();
