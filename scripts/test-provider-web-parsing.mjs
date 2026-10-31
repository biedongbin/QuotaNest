#!/usr/bin/env node
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { join, dirname, resolve, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { parseOllamaHTML, parseOpenCodeUsage } from '../Sources/TokenHUD/mjs/provider-web-parsing.mjs';

// Handcrafted, de-identified fixtures matching public field contracts. No upstream code is executed.
const root = mkdtempSync(join(tmpdir(), 'tokenhud-web-fixtures-'));
const source = resolve(dirname(fileURLToPath(import.meta.url)), '../Sources/TokenHUD/mjs');
after(() => {
  assert.equal(dirname(root), tmpdir());
  assert(basename(root).startsWith('tokenhud-web-fixtures-'));
  rmSync(root, { recursive: true, force: true });
});
const legacyPage = '<script>$R[5]={rollingUsage:$R[6]={status:"ok",usagePercent:0},weeklyUsage:$R[7]={status:"ok",usagePercent:21,resetInSec:120}};</script>';
const ollamaPage = '<section><span>Session usage</span><span>0% used</span></section>'
  + '<section><span>Weekly usage</span><span>8.5% used</span><div data-time="2030-01-02T03:04:05Z"></div></section>';
const loginPage = '<h1>Sign in</h1><form action="/signin"><input type="email"><input type="password"></form>';
const consoleStatus = { access: { endsAt: '2030-02-01T00:00:00Z', meters: {
  fiveHour: { usedMicroCents: '0', limitMicroCents: '1200000000', resetsAt: null },
  week: { usedMicroCents: '600000000', limitMicroCents: '3000000000', resetsAt: '2030-01-02T03:04:05Z' },
  month: { usedMicroCents: '1200000000', limitMicroCents: '6000000000' },
} } };

test('Ollama preserves zero and missing reset, with separate weekly data-time', () => {
  const result = parseOllamaHTML(ollamaPage);
  assert.deepEqual(result.five_hour, { used_percentage: 0, resets_at: null });
  assert.equal(result.seven_day.used_percentage, 8.5);
  assert.equal(result.seven_day.resets_at, Date.parse('2030-01-02T03:04:05Z') / 1000);
  assert.equal(result.monthly, undefined);
});
test('Ollama monthly dollar utilization retains actual amounts', () => {
  const result = parseOllamaHTML('<span>Monthly usage</span><span>$1.20 of $12.00 used</span>');
  assert.equal(result.monthly.used_percentage, 10);
  assert.equal(result.monthly.resets_at, null);
  assert.equal(result.windows[0].amount, 1.2);
  assert.equal(result.windows[0].limit, 12);
  assert.equal(result.five_hour, undefined);
});
test('Ollama free usage meter accepts width zero and hourly labels do not invent a five-hour period', () => {
  const result = parseOllamaHTML('<span>Free usage</span><div style="width: 0%;"></div><span>Hourly usage</span><span>2% used</span>');
  assert.equal(result.monthly.used_percentage, 0);
  assert.equal(result.five_hour, undefined);
  assert.equal(result.windows[1].label, '小时额度');
});
test('Ollama missing meters stay unknown and login HTML is classified as auth', () => {
  assert.equal(parseOllamaHTML('<span>Session usage</span><span>not available</span>'), null);
  assert.deepEqual(parseOllamaHTML(loginPage), { error: 'auth' });
  assert.equal(parseOllamaHTML('<script>"<span>Session usage</span>100% used"</script>'), null);
});
test('OpenCode reads static Seroval fields without executing scripts or inventing resets', () => {
  const result = parseOpenCodeUsage(legacyPage + '<script>globalThis.__quotaFixtureExecuted=true</script>', 2000000);
  assert.equal(globalThis.__quotaFixtureExecuted, undefined);
  assert.deepEqual(result.five_hour, { used_percentage: 0, resets_at: null });
  assert.deepEqual(result.seven_day, { used_percentage: 21, resets_at: 2120 });
  assert.equal(result.monthly, undefined);
});
test('OpenCode missing windows are absent instead of zero placeholders', () => {
  const result = parseOpenCodeUsage('<script>weeklyUsage:$R[7]={usagePercent:4};</script>');
  assert.equal(result.five_hour, undefined);
  assert.equal(result.seven_day.used_percentage, 4);
  assert.equal(result.monthly, undefined);
});
test('OpenCode Console micro-cent meters keep exact zero, amount units, and unknown month reset', () => {
  const result = parseOpenCodeUsage(JSON.stringify(consoleStatus));
  assert.deepEqual(result.five_hour, { used_percentage: 0, resets_at: null });
  assert.equal(result.seven_day.used_percentage, 20);
  assert.equal(result.monthly.used_percentage, 20);
  assert.equal(result.monthly.resets_at, null, 'Billing period end is not substituted for an absent meter reset');
  assert.equal(result.windows[0].limit, 12);
  assert.equal(result.windows[1].amount, 6);
  assert.equal(result.windows[1].unit, 'USD');
});
test('OpenCode explicit percentages below one remain percentages, not guessed fractions', () => {
  const result = parseOpenCodeUsage(JSON.stringify({ usage: { rolling: { percent: 0.5 }, monthly: { percent: 0, resetInSec: 0 } } }), 2000000);
  assert.equal(result.five_hour.used_percentage, 0.5);
  assert.equal(result.five_hour.resets_at, null);
  assert.equal(result.monthly.used_percentage, 0);
  assert.equal(result.monthly.resets_at, 2000);
});
test('OpenCode handles login HTML, empty Console shell, and absent subscription honestly', () => {
  assert.deepEqual(parseOpenCodeUsage(loginPage), { error: 'auth' });
  assert.equal(parseOpenCodeUsage('<html><div id="app"></div><script src="/console/assets/index.js"></script></html>'), null);
  assert.deepEqual(parseOpenCodeUsage('{"access":null}'), { error: 'no-subscription' });
  assert.equal(parseOpenCodeUsage('<script>rollingUsage:$R[1]={resetInSec:123};</script>'), null);
});

let seq = 0;
function runProvider(name, auth, routes) {
  const directory = join(root, String(seq++)); mkdirSync(directory);
  const hud = join(directory, 'hud'); mkdirSync(hud);
  const authFile = join(directory, 'auth.json'), cache = join(directory, 'cache.json');
  const fixture = join(directory, 'routes.json'), log = join(directory, 'requests.jsonl'), curl = join(directory, 'curl');
  writeFileSync(authFile, JSON.stringify(auth));
  writeFileSync(cache, '{"generatedAt":123,"seven_day":{"used_percentage":9}}');
  const prior = readFileSync(cache, 'utf8');
  writeFileSync(fixture, JSON.stringify(routes));
  writeFileSync(curl, `#!${process.execPath}\nconst fs=require('node:fs');const args=process.argv.slice(2);fs.appendFileSync(process.env.FIXTURE_LOG,JSON.stringify(args)+'\\n');const routes=JSON.parse(fs.readFileSync(process.env.FIXTURE_ROUTES,'utf8'));const entry=routes[args.at(-1)];if(!entry)process.exit(88);process.stdout.write((typeof entry.body==='string'?entry.body:JSON.stringify(entry.body))+'\\n'+(entry.status??200));\n`, { mode: 0o700 });
  const result = spawnSync(process.execPath, [join(source, `${name}-usage-provider.mjs`)], { encoding: 'utf8', timeout: 5000,
    env: { PATH: process.env.PATH, HOME: directory, CLAUDE_CONFIG_DIR: directory, TOKENHUD_HUD_DIR: hud,
      TOKENHUD_AUTH_FILE: authFile, TOKENHUD_CACHE_FILE: cache, TOKENHUD_STDOUT_ONLY: '1', TOKENHUD_CURL: curl,
      FIXTURE_LOG: log, FIXTURE_ROUTES: fixture } });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(cache, 'utf8'), prior, 'App-mode adapters must not write snapshots');
  const requests = readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line));
  assert(!JSON.stringify(requests).includes('do-not-use-model-key'));
  return { usage: JSON.parse(result.stdout), requests };
}
test('Ollama cookie transport uses settings HTML and never the model API key', () => {
  const { usage, requests } = runProvider('ollama', { cookieAuth: 'session=offline-cookie', refreshApiKey: 'do-not-use-model-key' }, {
    'https://ollama.com/settings': { body: ollamaPage },
  });
  assert.equal(usage.five_hour.used_percentage, 0);
  assert(requests[0].includes('Cookie: session=offline-cookie'));
  assert.equal(requests.length, 1);
});
test('Ollama signed-out HTML and login redirect report auth without zero quota', () => {
  for (const entry of [{ body: loginPage }, { body: '', status: 302 }]) {
    const { usage } = runProvider('ollama', { cookieAuth: 'session=offline-cookie' }, { 'https://ollama.com/settings': entry });
    assert.equal(usage.error, 'auth');
    assert.equal(usage.five_hour, undefined);
  }
});
test('OpenCode cookie discovers Console org then requests status with x-org-id', () => {
  const { usage, requests } = runProvider('oc-go', { cookieAuth: '__Host-console_session=offline', refreshApiKey: 'do-not-use-model-key' }, {
    'https://opencode.ai/console/api/orgs': { body: [{ id: 'org_fixture', name: 'Offline' }] },
    'https://opencode.ai/console/api/go/status': { body: consoleStatus },
  });
  assert.equal(usage.five_hour.used_percentage, 0);
  assert.equal(usage.monthly.resets_at, null);
  assert.equal(requests.length, 2);
  assert(requests[1].includes('x-org-id: org_fixture'));
});
test('OpenCode legacy auth falls back to verified workspace discovery and static page', () => {
  const fn = 'def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f';
  const { usage, requests } = runProvider('oc-go', { cookieAuth: 'auth=offline', refreshApiKey: 'do-not-use-model-key' }, {
    'https://opencode.ai/console/api/orgs': { body: {}, status: 401 },
    [`https://opencode.ai/_server?id=${fn}`]: { body: '$R[1]=[{id:"wrk_fixture",name:"Offline"}];' },
    'https://opencode.ai/console/api/go/status': { body: {}, status: 404 },
    'https://opencode.ai/workspace/wrk_fixture/go': { body: legacyPage },
  });
  assert.equal(usage.five_hour.used_percentage, 0);
  assert.equal(usage.five_hour.resets_at, null);
  assert.equal(requests.length, 4);
  assert(requests[1].includes(`X-Server-Id: ${fn}`));
});
test('OpenCode expired Console cookie does not fall back to another credential', () => {
  const { usage, requests } = runProvider('oc-go', { cookieAuth: '__Host-console_session=offline', refreshApiKey: 'do-not-use-model-key' }, {
    'https://opencode.ai/console/api/orgs': { body: {}, status: 401 },
  });
  assert.equal(usage.error, 'auth');
  assert.equal(requests.length, 1);
});
test('OpenCode Console orgs HTTP 200 login HTML reports auth without legacy or API-key fallback', () => {
  for (const cookieAuth of ['__Host-console_session=offline', 'auth=offline']) {
    const { usage, requests } = runProvider('oc-go', { cookieAuth, refreshApiKey: 'do-not-use-model-key' }, {
      'https://opencode.ai/console/api/orgs': { body: loginPage },
    });
    assert.equal(usage.error, 'auth');
    assert.equal(usage.five_hour, undefined);
    assert.equal(requests.length, 1);
  }
});
test('OpenCode legacy signed-out page is auth, never fabricated zero windows', () => {
  const { usage } = runProvider('oc-go', { workspaceID: 'wrk_fixture', cookieAuth: 'auth=offline' }, {
    'https://opencode.ai/console/api/go/status': { body: {}, status: 404 },
    'https://opencode.ai/workspace/wrk_fixture/go': { body: loginPage },
  });
  assert.equal(usage.error, 'auth');
  assert.equal(usage.five_hour, undefined);
});
