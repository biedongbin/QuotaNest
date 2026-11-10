#!/usr/bin/env node
// Offline fixtures only: every HTTP executable is replaced with a local fake curl.
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, mkdirSync, rmSync, readdirSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, basename, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { normalizeUsage } from '../Sources/TokenHUD/mjs/usage-normalize.mjs';
import { entryRevision } from '../Sources/TokenHUD/mjs/hud-runtime.mjs';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(repo, 'Sources/TokenHUD/mjs');
const temp = mkdtempSync(join(tmpdir(), 'tokenhud-query-fixtures-'));
const hud = join(temp, 'custom-hud');
mkdirSync(hud);
const authFile = join(temp, 'isolated-auth.json');
const cacheFile = join(temp, 'isolated-cache.json');
const argsFile = join(temp, 'curl-args.json');
const curl = join(temp, 'fake-curl');
writeFileSync(curl, `#!${process.execPath}\nimport('node:fs').then(fs => { fs.writeFileSync(process.env.FIXTURE_ARGS, JSON.stringify(process.argv.slice(2))); process.stdout.write(process.env.FIXTURE_BODY + (process.argv.includes('-w') ? '\\n' + process.env.FIXTURE_STATUS : '')); });\n`, { mode: 0o700 });
const env = {
  PATH: process.env.PATH, HOME: temp, CLAUDE_CONFIG_DIR: temp,
  TOKENHUD_HUD_DIR: hud, TOKENHUD_AUTH_FILE: authFile, TOKENHUD_CACHE_FILE: cacheFile,
  TOKENHUD_CURL: curl, TOKENHUD_STDOUT_ONLY: '1', FIXTURE_ARGS: argsFile,
};
let count = 0;
function run(name, auth, body, status = 200, extra = {}) {
  writeFileSync(authFile, JSON.stringify(auth));
  writeFileSync(cacheFile, JSON.stringify({ generatedAt: 123, seven_day: { used_percentage: 9 } }));
  const before = readFileSync(cacheFile, 'utf8');
  const result = spawnSync(process.execPath, [join(source, `${name}-usage-provider.mjs`)], {
    env: { ...env, FIXTURE_BODY: typeof body === 'string' ? body : JSON.stringify(body), FIXTURE_STATUS: String(status), ...extra },
    encoding: 'utf8', timeout: 5000,
  });
  assert.equal(result.status, 0, `${name}: ${result.stderr}`);
  assert.equal(readFileSync(cacheFile, 'utf8'), before, `${name} must not write cache in App mode`);
  count++;
  return JSON.parse(result.stdout);
}
function args() { return JSON.parse(readFileSync(argsFile, 'utf8')); }
try {
  const quotaAuth = { tokenhudResolvedAuth: true, quotaMode: 'endpoint', queryUrl: 'https://quota.invalid/exact?scope=one', queryKey: 'quota-only-key', refreshApiKey: 'model-call-key' };
  let result = run('generic', quotaAuth, { data: { '5h': { used_percentage: 12 }, week: { used_percentage: '24' }, month: { used_percentage: 36 } } });
  assert.equal(result.five_hour.used_percentage, 12);
  assert.equal(result.seven_day.used_percentage, 24);
  assert.equal(result.monthly.used_percentage, 36);
  assert.equal(result.five_hour.resets_at, null);
  assert.equal(args().at(-1), quotaAuth.queryUrl);
  assert(args().includes('Authorization: Bearer quota-only-key'));
  assert(!JSON.stringify(args()).includes('model-call-key'));
  result = run('generic', quotaAuth, { windows: [{ label: '2小时', used_percentage: 7, resets_at: 'invalid' }, { label: '美元', amount: 3, limit: 20, unit: 'USD' }] });
  assert.equal(result.windows.length, 2);
  assert.equal(result.windows[0].resets_at, null);
  for (const [status, error] of [[401, 'auth'], [429, 'ratelimit'], [500, 'network']]) {
    assert.equal(run('generic', quotaAuth, {}, status).error, error);
  }
  assert.equal(run('generic', quotaAuth, '<html>not JSON</html>').error, 'parse');
  const marker = readFileSync(argsFile, 'utf8');
  assert.equal(run('generic', { ...quotaAuth, quotaMode: 'none' }, {}).error, 'no-query');
  assert.equal(readFileSync(argsFile, 'utf8'), marker, 'disabled quota must not invoke curl');
  assert.equal(run('generic', { ...quotaAuth, queryKey: '' }, {}).error, 'no-auth');
  assert.equal(readFileSync(argsFile, 'utf8'), marker, 'missing quota key must not use model key');

  result = run('oc-go', { workspaceID: 'wrk_fixture', cookieAuth: 'session=fixture-cookie', queryKey: 'quota-key', refreshApiKey: 'model-call-key' }, { usage: { rolling: { percent: 18 }, weekly: { percent: 22, resetsAt: 'bad' } } });
  assert.equal(result.five_hour.used_percentage, 18);
  assert.equal(result.five_hour.resets_at, null);
  assert.equal(result.seven_day.resets_at, null);
  assert(args().includes('Cookie: session=fixture-cookie'));
  assert(!JSON.stringify(args()).includes('Bearer'));
  result = run('oc-go', { refreshApiKey: 'legacy-key' }, { usage: { monthly: { percent: 8 } } });
  assert.equal(result.monthly.used_percentage, 8);
  assert(args().includes('Authorization: Bearer legacy-key'));
  assert.equal(run('oc-go', { workspaceID: 'wrk_fixture', cookieAuth: 'session=fixture-cookie' }, '<html>unknown page</html>').error, 'parse');
  result = run('ollama', { cookieAuth: 'session=fixture-cookie', refreshApiKey: 'model-call-key' }, { included: { session: { remaining_percent: 72 }, weekly: { remaining_percent: 85 } } });
  assert.equal(result.five_hour.used_percentage, 28);
  assert.equal(result.five_hour.resets_at, null);
  assert(args().includes('Cookie: session=fixture-cookie'));
  result = run('ollama', { headers: { Authorization: 'Bearer legacy-key' } }, { included: { balance_usd: 75, allowance_usd: 100 } });
  assert.equal(result.monthly.used_percentage, 25);
  assert.equal(result.monthly.resets_at, null);
  assert(args().includes('Authorization: Bearer legacy-key'));
  assert.equal(run('ollama', { cookieAuth: 'session=fixture-cookie' }, '<html>unknown page</html>').error, 'parse');

  const glmAuth = JSON.parse(readFileSync(join(repo, 'Sources/TokenHUD/providers/glm/auth-template.json'), 'utf8'));
  glmAuth.headers = { authorization: 'fixture-web-token', Authorization: 'Bearer model-call-key' };
  glmAuth.five_hour.resetsAtTimes = ['00:00'];
  result = run('glm', glmAuth, { code: 200, data: { limits: [{ unit: 3, percentage: 23 }, { unit: 6, percentage: 17 }] } }, 200, { USAGE_PROVIDER_NAME: 'glm' });
  assert.equal(result.five_hour.used_percentage, 23);
  assert.equal(result.five_hour.resets_at, null, 'local schedule must not invent reset');
  assert(args().includes('authorization: fixture-web-token'));
  assert(!JSON.stringify(args()).includes('model-call-key'));
  result = run('cline', { apiKey: 'fixture-cline-key' }, { data: { limits: [{ type: 'five_hour', percentUsed: 11 }] } });
  assert.equal(result.five_hour.used_percentage, 11);
  const codex = join(temp, 'codex'); mkdirSync(codex);
  writeFileSync(join(codex, 'auth.json'), JSON.stringify({ auth_mode: 'chatgpt', tokens: { access_token: 'fixture-access-token', account_id: 'fixture-account' } }));
  result = run('gpt', {}, { rate_limit: { primary_window: { used_percent: 19, limit_window_seconds: 18000 } } }, 200, { CODEX_HOME: codex });
  assert.equal(result.five_hour.used_percentage, 19);

  // Verify fetch wrapper honors all explicit paths, without falling back to ~/.claude/hud.
  for (const file of readdirSync(source).filter(file => file.endsWith('.mjs'))) copyFileSync(join(source, file), join(hud, file));
  writeFileSync(authFile, JSON.stringify({ refreshApiKey: 'fixture-key' }));
  const fetch = join(temp, 'fetch.sh');
  writeFileSync(fetch, readFileSync(join(repo, 'Sources/TokenHUD/providers/opencode-go/fetch.sh'), 'utf8').replaceAll('{SLUG}', 'fixture-account'));
  const wrapped = spawnSync('/bin/zsh', [fetch], { env: { ...env, TOKENHUD_NODE: process.execPath, FIXTURE_BODY: JSON.stringify({ usage: { rolling: { percent: 4 } } }), FIXTURE_STATUS: '200' }, encoding: 'utf8', timeout: 5000 });
  assert.equal(wrapped.status, 0, wrapped.stderr);
  assert.equal(JSON.parse(wrapped.stdout).five_hour.used_percentage, 4);
  count++;

  writeFileSync(join(temp, 'settings.json'), JSON.stringify({ env: { ACCOUNT_ENVS: 'glm-one,glm-two,Claude-Max' } }));
  const hudEntries = {
    'glm-one': { schemaVersion: 2, label: 'GLM one', cache: join(hud, '.glm-one-hud-cache.json'), buckets: {} },
    'glm-two': { schemaVersion: 2, label: 'GLM two', cache: join(hud, '.glm-two-hud-cache.json'), buckets: {} },
  };
  writeFileSync(join(hud, 'envs.json'), JSON.stringify(hudEntries));
  writeFileSync(hudEntries['glm-one'].cache, JSON.stringify({ configuration: entryRevision(hudEntries['glm-one']), generatedAt: Date.now(), windows: [{ label: '2小时', used_percentage: 31 }, { label: '美元', amount: 5, limit: 10, unit: 'USD' }] }));
  writeFileSync(hudEntries['glm-two'].cache, JSON.stringify({ configuration: entryRevision(hudEntries['glm-two']), generatedAt: Date.now(), windows: [{ label: '本月', used_percentage: 42 }] }));
  const rendered = spawnSync(process.execPath, [join(source, 'statusline.mjs')], { env, input: JSON.stringify({ cwd: temp, rate_limits: { five_hour: { used_percentage: 6 } } }), encoding: 'utf8', timeout: 5000 });
  assert.equal(rendered.status, 0, rendered.stderr);
  const text = rendered.stdout.replace(/\x1b\[[0-9;]*m/g, '');
  for (const part of ['GLM one', 'GLM two', '2小时:', '31%', '5/10 USD', '42%', 'Max', '6%']) assert(text.includes(part), part);
  count++;
  assert.equal(normalizeUsage({ windows: [{ label: 'bad', used_percentage: 'oops' }] }), null);
  console.log(`PASS ${count} offline provider/HUD fixture scenarios; no account network used`);
} finally {
  assert(basename(temp).startsWith('tokenhud-query-fixtures-'));
  assert.equal(dirname(temp), tmpdir());
  rmSync(temp, { recursive: true, force: true });
}
