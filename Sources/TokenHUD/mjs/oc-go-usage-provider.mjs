#!/usr/bin/env node
// Cookie: verified Console API, with static legacy workspace HTML/Seroval fallback.
// API-key mode retains the Zen usage endpoint. Source contracts are documented in docs/.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseOpenCodeUsage, openCodeWorkspaceIDs, validWorkspaceID } from './provider-web-parsing.mjs';

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const HUD_DIR = process.env.TOKENHUD_HUD_DIR || join(CLAUDE_DIR, 'hud');
const AUTH_FILE = process.env.TOKENHUD_AUTH_FILE || process.env.USAGE_AUTH_FILE || join(HUD_DIR, '.oc-go-usage-auth.json');
const CACHE_FILE = process.env.TOKENHUD_CACHE_FILE || process.env.USAGE_CACHE_FILE || join(HUD_DIR, '.oc-go-usage-cache.json');
const TTL_MS = 60_000;
const BASE = 'https://opencode.ai';
// Public Solid server-function selector, not a credential. Kept only for legacy workspace discovery.
const WORKSPACES_FUNCTION = 'def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f';
const deadline = Date.now() + 18000;
const readJson = path => { try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; } };
const writeCache = obj => {
  if (process.env.TOKENHUD_STDOUT_ONLY === '1') { process.stdout.write(JSON.stringify(obj) + '\n'); return; }
  try { mkdirSync(HUD_DIR, { recursive: true }); writeFileSync(CACHE_FILE, JSON.stringify(obj, null, 2)); } catch {}
};
const fail = error => {
  const previous = readJson(CACHE_FILE);
  writeCache({ ...(previous || {}), error, stale: true, lastAttemptAt: Date.now(), ttlMs: TTL_MS });
};
function request(url, credential, extraHeaders = []) {
  const remaining = Math.min(6, (deadline - Date.now()) / 1000);
  if (remaining <= 0) return { error: 'network' };
  const result = spawnSync(process.env.TOKENHUD_CURL || '/usr/bin/curl', [
    '-sS', '--connect-timeout', String(Math.min(3, remaining)), '--max-time', String(remaining), '--proto', '=https,http',
    '-H', credential, '-H', 'Accept: application/json,text/html;q=0.9,*/*;q=0.8',
    '-H', 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/143.0.0.0 Safari/537.36',
    ...extraHeaders.flatMap(value => ['-H', value]),
    '-w', '\n%{http_code}', '--url', url,
  ], { encoding: 'utf8', timeout: Math.ceil(remaining * 1000) + 100, killSignal: 'SIGKILL',
    maxBuffer: 2_000_000, stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.error || result.status !== 0) return { error: 'network' };
  const separator = result.stdout.lastIndexOf('\n');
  const status = Number(result.stdout.slice(separator + 1).trim());
  const text = result.stdout.slice(0, separator);
  const error = [401, 403, 301, 302, 303, 307, 308].includes(status) ? 'auth'
    : status === 429 ? 'ratelimit' : status === 200 ? null : 'network';
  return { status, text, error };
}
function configuredWorkspace(auth) {
  const explicit = auth.workspaceID ?? auth.workspaceId;
  if (validWorkspaceID(explicit)) return explicit;
  try {
    const url = new URL(process.env.TOKENHUD_QUERY_URL || auth.queryUrl || auth.apiUrl || BASE);
    if (url.protocol !== 'https:' || url.hostname !== 'opencode.ai') return null;
    const id = /^\/(?:workspace|console)\/((?:wrk_|org_)[A-Za-z0-9_-]+)(?:\/|$)/.exec(url.pathname)?.[1];
    return validWorkspaceID(id) ? id : null;
  } catch { return null; }
}
function cookieUsage(auth, cookie) {
  const credential = `Cookie: ${cookie}`;
  const legacyCookie = /(?:^|;\s*)(?:auth|__Host-auth)=/.test(cookie);
  let workspace = configuredWorkspace(auth);
  if (!workspace) {
    const orgs = request(`${BASE}/console/api/orgs`, credential);
    if (!orgs.error) workspace = openCodeWorkspaceIDs(orgs.text)[0];
    if (!workspace && !orgs.error && parseOpenCodeUsage(orgs.text)?.error === 'auth') {
      return { error: 'auth' };
    }
    if (!workspace && (!legacyCookie || orgs.error === 'ratelimit' || orgs.error === 'network')) {
      return { error: orgs.error || 'parse' };
    }
    if (!workspace) {
      const legacy = request(`${BASE}/_server?id=${WORKSPACES_FUNCTION}`, credential, [
        `X-Server-Id: ${WORKSPACES_FUNCTION}`, `X-Server-Instance: server-fn:${randomUUID()}`,
        `Origin: ${BASE}`, `Referer: ${BASE}`,
      ]);
      if (legacy.error) return { error: legacy.error };
      workspace = openCodeWorkspaceIDs(legacy.text)[0];
      if (!workspace) return { error: parseOpenCodeUsage(legacy.text)?.error || 'parse' };
    }
  }
  const consoleResult = request(`${BASE}/console/api/go/status`, credential, [`x-org-id: ${workspace}`]);
  if (!consoleResult.error) {
    const usage = parseOpenCodeUsage(consoleResult.text);
    if (usage) return usage;
  }
  if (!legacyCookie || !workspace.startsWith('wrk_') || consoleResult.error === 'ratelimit'
      || (consoleResult.error === 'network' && consoleResult.status !== 404)) {
    return { error: consoleResult.error || 'parse' };
  }
  const legacy = request(`${BASE}/workspace/${workspace}/go`, credential);
  if (legacy.error) return { error: legacy.error };
  return parseOpenCodeUsage(legacy.text) || { error: 'parse' };
}
function main() {
  const auth = readJson(AUTH_FILE) || {};
  const cookie = String(auth.cookieAuth || '').trim();
  const key = String(auth.queryKey ?? auth.refreshApiKey ?? '').trim();
  if ((!cookie && !key) || /[\r\n]/.test(cookie || key)) { fail('no-auth'); return; }
  let usage;
  if (cookie) usage = cookieUsage(auth, cookie);
  else {
    const url = process.env.TOKENHUD_QUERY_URL || auth.queryUrl || auth.apiUrl || `${BASE}/zen/go/v1/usage`;
    const result = request(url, `Authorization: Bearer ${key}`);
    usage = result.error ? { error: result.error } : parseOpenCodeUsage(result.text);
  }
  if (!usage || usage.error) { fail(usage?.error || 'parse'); return; }
  writeCache({ ...usage, generatedAt: Date.now(), ttlMs: TTL_MS, error: null, stale: false });
}
main();
