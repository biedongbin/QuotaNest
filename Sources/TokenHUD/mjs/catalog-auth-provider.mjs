#!/usr/bin/env node
// Fixed provider endpoints; reads only the per-account core query snapshot.
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { parseAuthUsage } from './auth-usage-parsers.mjs';
export const authProviders = Object.freeze({
  'claude-code': { url: 'https://api.anthropic.com/api/oauth/usage', headers: { 'anthropic-beta': 'oauth-2025-04-20' } },
  antigravity: { url: 'https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary', method: 'POST', headers: { 'User-Agent': 'antigravity/hub/2.23.0 darwin/arm64' } },
  'gemini-cli': { url: 'https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota', method: 'POST' },
  'github-copilot': { url: 'https://api.github.com/copilot_internal/user', scheme: 'token', headers: { 'X-GitHub-Api-Version': '2022-11-28' } },
  devin: { url: 'https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus', method: 'POST', bodyToken: true, headers: { 'Connect-Protocol-Version': '1' } },
  'grok-cli': { url: 'https://cli-chat-proxy.grok.com/v1/billing?format=credits', headers: { 'x-xai-token-auth': ['xai', 'grok', 'cli'].join('-'), 'x-grok-client-version': '1.0.46' } },
});
const readJSON = path => { try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; } };
const clean = value => typeof value === 'string' && value.trim() && !/[\r\n\0]/.test(value) ? value.trim() : '';
const projectId = value => clean(typeof value === 'string' ? value : value?.id);
export function main() {
  const provider = process.env.USAGE_PROVIDER_NAME, config = authProviders[provider];
  const hud = process.env.TOKENHUD_HUD_DIR || join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'hud');
  const authFile = process.env.TOKENHUD_AUTH_FILE;
  const cacheFile = process.env.TOKENHUD_CACHE_FILE || process.env.USAGE_CACHE_FILE || join(hud, `.${provider}-usage-cache.json`);
  const emit = value => {
    if (process.env.TOKENHUD_STDOUT_ONLY === '1') process.stdout.write(JSON.stringify(value) + '\n');
    else { mkdirSync(dirname(cacheFile), { recursive: true }); writeFileSync(cacheFile, JSON.stringify(value, null, 2)); }
  };
  const fail = (error, message) => emit({ error, ...(message ? { message } : {}), stale: true, lastAttemptAt: Date.now(), ttlMs: 60_000 });
  if (!config) { fail('no-query'); return; }
  const snapshot = authFile ? readJSON(authFile) : null;
  if (snapshot?.authMode && snapshot.authMode !== 'auth') { fail('no-query', '此类型的 API Key 模式不支持订阅额度查询，请使用 Auth 文件。'); return; }
  const key = clean(snapshot?.queryKey);
  if (!key) { fail('no-auth', '请选择此账号的认证 JSON；过期授权请由原客户端更新。'); return; }
  const context = snapshot?.tokenhudAuthContext;
  const headers = { 'Accept': 'application/json', 'Content-Type': 'application/json', 'User-Agent': 'TokenHUD/1.0', ...config.headers };
  if (!config.bodyToken) headers.Authorization = `${config.scheme || 'Bearer'} ${key}`;
  if (provider === 'grok-cli' && clean(context?.userId)) headers['x-userid'] = clean(context.userId);
  const request = (url, body, method = config.method || 'GET') => {
    const args = ['-q', '-sS', '--connect-timeout', '3', '--max-time', '12', '--proto', '=https', '-X', method];
    for (const [name, value] of Object.entries(headers)) args.push('-H', `${name}: ${value}`);
    if (body !== undefined) args.push('--data-binary', JSON.stringify(body));
    args.push('-w', '\n%{http_code}', '--url', url);
    const result = spawnSync(process.env.TOKENHUD_CURL || '/usr/bin/curl', args, { encoding: 'utf8', timeout: 13_000, killSignal: 'SIGKILL', maxBuffer: 2_000_000, stdio: ['ignore', 'pipe', 'pipe'] });
    if (result.error || result.status !== 0) return { error: 'network' };
    const separator = result.stdout.lastIndexOf('\n'), status = Number(result.stdout.slice(separator + 1).trim());
    if (status === 401 || status === 403) return { error: 'auth' };
    if (status === 429) return { error: 'ratelimit' };
    if (status < 200 || status >= 300 || separator < 0) return { error: 'network' };
    try { return { data: JSON.parse(result.stdout.slice(0, separator)) }; } catch { return { error: 'parse' }; }
  };
  let body;
  if (provider === 'antigravity' || provider === 'gemini-cli') {
    let project = projectId(context?.projectId) || projectId(context?.providerProjectId);
    if (!project && provider === 'gemini-cli') {
      const discovery = request('https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist', { metadata: { ideType: 9, platform: 2, pluginType: 2 } }, 'POST');
      if (discovery.error) { fail(discovery.error); return; }
      project = projectId(discovery.data?.cloudaicompanionProject);
    }
    if (!project) { fail('no-auth', '此认证未提供可用 Code Assist project；请由原客户端完成项目设置后更新认证。'); return; }
    body = { project };
  } else if (provider === 'devin') {
    // Complete GetUserStatus metadata from CPA requests.ts; no Authorization token.
    body = { metadata: { ideName: 'chisel', ideVersion: '3000.10.21', apiKey: key, locale: 'en', os: 'darwin', extensionVersion: '3000.10.21', clientName: 'chisel' } };
  }
  const response = request(config.url, body);
  if (response.error) { fail(response.error); return; }
  const usage = parseAuthUsage(provider, response.data);
  if (!usage) { fail('parse', '服务端未返回可识别额度，当前用量未知。'); return; }
  emit({ ...usage, generatedAt: Date.now(), ttlMs: 60_000, error: null, stale: false });
}
if (process.argv[1] && realpathSync(resolve(process.argv[1])) === realpathSync(fileURLToPath(import.meta.url))) main();
