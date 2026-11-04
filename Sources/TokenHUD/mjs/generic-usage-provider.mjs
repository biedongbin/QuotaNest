#!/usr/bin/env node
// Explicit quota endpoint only. Does not call models or infer billing endpoints.
// App owns snapshot persistence; this adapter emits UsageCache JSON on stdout.
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { normalizeUsage } from './usage-normalize.mjs';

const hudDir = process.env.TOKENHUD_HUD_DIR || join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'hud');
const authFile = process.env.TOKENHUD_AUTH_FILE || process.env.USAGE_AUTH_FILE || join(hudDir, '.custom-usage-auth.json');
const emit = value => process.stdout.write(JSON.stringify({ ...value, lastAttemptAt: Date.now() }) + '\n');
function main() {
  let auth;
  try { auth = JSON.parse(readFileSync(authFile, 'utf8')); }
  catch { emit({ error: 'no-auth', stale: true }); return; }
  if (auth?.tokenhudResolvedAuth !== true) { emit({ error: 'no-auth', stale: true }); return; }
  const mode = process.env.TOKENHUD_QUOTA_MODE || auth.quotaMode;
  if (mode !== 'endpoint') { emit({ error: 'no-query', stale: true }); return; }
  const endpoint = process.env.TOKENHUD_QUERY_URL || auth.queryUrl || '';
  let url;
  try { url = new URL(endpoint); } catch { emit({ error: 'no-query', stale: true }); return; }
  if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) {
    emit({ error: 'no-query', stale: true }); return;
  }
  const key = typeof auth.queryKey === 'string' ? auth.queryKey.trim() : '';
  if (!key || /[\x00-\x1f\x7f]/.test(key)) { emit({ error: 'no-auth', stale: true }); return; }
  const projected = auth.headers;
  if (Object.hasOwn(auth, 'headers') && (!projected || typeof projected !== 'object' || Array.isArray(projected))) {
    emit({ error: 'no-auth', stale: true }); return;
  }
  const headers = Object.entries(projected || {});
  if (headers.some(([name, value]) => !/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name)
      || typeof value !== 'string' || /[\x00-\x1f\x7f]/.test(value))) {
    emit({ error: 'no-auth', stale: true }); return;
  }
  if (!headers.length) headers.push(['Authorization', `Bearer ${key}`]);
  if (!headers.some(([name]) => name.toLowerCase() === 'accept')) headers.push(['Accept', 'application/json']);
  const response = spawnSync(process.env.TOKENHUD_CURL || '/usr/bin/curl', [
    '-q', '-sS', '--connect-timeout', '6', '--max-time', '12', '--proto', '=https,http',
    ...headers.flatMap(([name, value]) => ['-H', `${name}: ${value}`]),
    '-w', '\n%{http_code}', '--url', url.href,
  ], { encoding: 'utf8', timeout: 15000, maxBuffer: 2_000_000, stdio: ['ignore', 'pipe', 'pipe'] });
  if (response.error || response.status !== 0) { emit({ error: 'network', stale: true }); return; }
  const split = response.stdout.lastIndexOf('\n');
  const status = Number(response.stdout.slice(split + 1).trim());
  if (status === 401 || status === 403) { emit({ error: 'auth', stale: true }); return; }
  if (status === 429) { emit({ error: 'ratelimit', stale: true }); return; }
  if (status !== 200) { emit({ error: 'network', stale: true }); return; }
  let raw;
  try { raw = JSON.parse(response.stdout.slice(0, split)); }
  catch { emit({ error: 'parse', stale: true }); return; }
  const usage = normalizeUsage(raw);
  if (!usage) { emit({ error: 'parse', stale: true }); return; }
  if (raw.error || raw.data?.error) { emit({ error: 'api', stale: true }); return; }
  emit({ ...usage, generatedAt: Date.now(), error: null, stale: false });
}
main();
