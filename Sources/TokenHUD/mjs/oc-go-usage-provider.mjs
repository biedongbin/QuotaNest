#!/usr/bin/env node
// OpenCode Go 用量 provider: Zen API v1 usage (Bearer key -> JSON, 稳定)
// 旧路线 (workspace 页 SSR HTML 解析) 已废弃: 网站改客户端渲染, SSR 不再内联 usage 数据
// auth: { refreshApiKey (Bearer, 即 API key), apiUrl(可选覆盖 usage 端点) }
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const HUD_DIR = join(CLAUDE_DIR, 'hud');
const AUTH_FILE = process.env.USAGE_AUTH_FILE || join(HUD_DIR, '.oc-go-usage-auth.json');
const CACHE_FILE = process.env.USAGE_CACHE_FILE || join(HUD_DIR, '.oc-go-usage-cache.json');
const TTL_MS = 60_000;
const verbose = !!process.env.USAGE_VERBOSE;

const readJson = (p, def) => {
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return def; }
};
const writeCache = (obj) => {
  try { mkdirSync(HUD_DIR, { recursive: true }); writeFileSync(CACHE_FILE, JSON.stringify(obj, null, 2)); } catch {}
};

const DEFAULT_URL = 'https://opencode.ai/zen/go/v1/usage';

function main() {
  const auth = readJson(AUTH_FILE, null);
  if (!auth || !auth.refreshApiKey) {
    writeCache({ error: 'no-auth', generatedAt: Date.now(), ttlMs: TTL_MS });
    if (verbose) console.error('[oc-go-provider] missing refreshApiKey');
    return;
  }
  const url = auth.apiUrl && auth.apiUrl.includes('/usage') ? auth.apiUrl : DEFAULT_URL;
  const r = spawnSync('curl', [
    '-s', '--max-time', '10',
    '-H', `Authorization: Bearer ${auth.refreshApiKey}`,
    url,
  ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  if (r.error || r.status !== 0 || !r.stdout) {
    writeCache({ error: 'network', generatedAt: Date.now(), ttlMs: TTL_MS, stale: true });
    if (verbose) console.error('[oc-go-provider] curl failed:', r.error?.message || ('exit ' + r.status));
    return;
  }
  let data;
  try { data = JSON.parse(r.stdout); } catch {
    writeCache({ error: 'parse', generatedAt: Date.now(), ttlMs: TTL_MS, stale: true });
    if (verbose) console.error('[oc-go-provider] non-JSON:', r.stdout.slice(0, 120));
    return;
  }
  const u = data && data.usage;
  if (!u) {
    writeCache({ error: 'parse', generatedAt: Date.now(), ttlMs: TTL_MS, stale: true });
    if (verbose) console.error('[oc-go-provider] no usage:', r.stdout.slice(0, 120));
    return;
  }
  const bucket = (b) => !b ? null : {
    used_percentage: typeof b.percent === 'number' ? b.percent : null,
    resets_at: b.resetsAt ? Math.floor(Date.parse(b.resetsAt) / 1000) : null,
  };
  writeCache({
    five_hour: bucket(u.rolling),
    seven_day: bucket(u.weekly),
    monthly: bucket(u.monthly),
    generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false,
  });
  if (verbose) console.error('[oc-go-provider] ok');
}

main();
