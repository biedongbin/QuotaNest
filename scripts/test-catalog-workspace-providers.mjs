#!/usr/bin/env node
// Offline real zsh wrapper + fake curl; no vendor traffic or credential discovery.
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, createHmac } from 'node:crypto';
import { workspaceProviders, parseWorkspaceUsage } from '../Sources/TokenHUD/mjs/catalog-workspace-provider.mjs';
import { normalizeUsage } from '../Sources/TokenHUD/mjs/usage-normalize.mjs';
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const temp = mkdtempSync(join(tmpdir(), 'tokenhud-workspace-'));
const hud = join(temp, 'hud'); mkdirSync(hud);
copyFileSync(join(repo, 'Sources/TokenHUD/mjs/catalog-workspace-provider.mjs'), join(hud, 'catalog-workspace-provider.mjs'));
const snapshotFile = join(temp, 'snapshot.json'), cacheFile = join(temp, 'cache.json'), argsFile = join(temp, 'args.json'), externalFile = join(temp, 'external.json');
const original = '{"access":"sourceB","refresh":"never-refreshB"}\n'; writeFileSync(externalFile, original);
const curl = join(temp, 'fake-curl.mjs');
writeFileSync(curl, `#!${process.execPath}\nimport {writeFileSync} from 'node:fs';\nwriteFileSync(process.env.FIXTURE_ARGS,JSON.stringify(process.argv.slice(2)));\nprocess.stdout.write(process.env.FIXTURE_BODY+'\\n'+process.env.FIXTURE_STATUS);\nprocess.exit(Number(process.env.FIXTURE_EXIT||0));\n`, { mode: 0o700 });
const fixtures = {
  'zcode-start': { code: 0, data: { server_time: 1800000000, plans: [{ status: 'active', user_plan_id: 'live', name: 'Start', starts_at: 1700000000, ends_at: 1900000000 }, { status: 'active', user_plan_id: 'future', starts_at: 1850000000 }, { status: 'active', user_plan_id: 'old', ends_at: 1750000000 }], balances: [{ user_plan_id: 'live', show_name: 'GLM', remaining_units: 50, total_units: 100, used_units: 50, expires_at: 1900000000 }, { user_plan_id: 'future', remaining_units: 999 }, { user_plan_id: 'old', remaining_units: 999 }] } },
  joycode: { code: 0, data: { usageItems: [{ title: '月积分', used: 20, remain: 80, total: 100, usedPercent: 20, unit: '积分', expireText: '2027年1月1日' }] } },
  raccoon: { code: 0, data: { available_points: 73 } },
  'autoclaw-cn': { code: 0, data: { total_balance: 100, wallets: [{ display_name: '订阅', balance: 80 }, { display_name: '隐藏', balance: 200, display: false }, { public_wallet_type: 'gift', balance: 20 }] } },
  autoclaw: { code: 0, data: { total_balance: 100, wallets: [{ display_name: '订阅', balance: 80 }] } },
};
let scenarios = 0;
function run(provider, body, { auth = {}, status = 200, exit = 0, stdoutOnly = true } = {}) {
  const snapshot = JSON.stringify({ authMode: 'auth', queryKey: 'snapshotA', tokenhudAuthContext: { device: 'deviceA', tenant: '租户A', loginType: 'PIN_JD_CLOUD' }, apiKey: 'sourceB', token: 'sourceB', queryUrl: 'https://attacker.invalid/', cookieAuth: 'cookieB', externalAuthFile: externalFile, ...auth });
  writeFileSync(snapshotFile, snapshot);
  const cached = JSON.stringify({ windows: [{ label: '旧余额', amount: 7, unit: 'credits', period: 'balance' }], generatedAt: 42 }); writeFileSync(cacheFile, cached);
  // Remove only the known fixture log, so a missing credential proves no curl ran.
  if (existsSync(argsFile)) { assert.equal(resolve(argsFile), join(temp, 'args.json')); rmSync(argsFile); }
  const wrapper = join(temp, 'fetch.sh');
  writeFileSync(wrapper, readFileSync(join(repo, `Sources/TokenHUD/providers/${provider}/fetch.sh`), 'utf8').replaceAll('{SLUG}', 'fixture'));
  const result = spawnSync('/bin/zsh', [wrapper], { encoding: 'utf8', timeout: 5000, env: { PATH: process.env.PATH, HOME: temp, TOKENHUD_NODE: process.execPath, TOKENHUD_HUD_DIR: hud, TOKENHUD_AUTH_FILE: snapshotFile, TOKENHUD_CACHE_FILE: cacheFile, TOKENHUD_STDOUT_ONLY: stdoutOnly ? '1' : '0', TOKENHUD_CURL: curl, TOKENHUD_QUERY_URL: 'https://attacker.invalid', FIXTURE_ARGS: argsFile, FIXTURE_BODY: typeof body === 'string' ? body : JSON.stringify(body), FIXTURE_STATUS: String(status), FIXTURE_EXIT: String(exit) } });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(snapshotFile, 'utf8'), snapshot);
  assert.equal(readFileSync(externalFile, 'utf8'), original);
  const output = JSON.parse(result.stdout);
  if (stdoutOnly) assert.equal(readFileSync(cacheFile, 'utf8'), cached);
  else assert.deepEqual(JSON.parse(readFileSync(cacheFile, 'utf8')), output);
  scenarios++;
  return { output, args: existsSync(argsFile) ? JSON.parse(readFileSync(argsFile, 'utf8')) : null };
}
try {
  for (const [provider, fixture] of Object.entries(fixtures)) {
    const manifest = JSON.parse(readFileSync(join(repo, `Sources/TokenHUD/providers/${provider}/manifest.json`), 'utf8'));
    assert.equal(manifest.autoCreateDefault, false); assert.equal(manifest.quotaMode, 'script'); assert.equal(manifest.credentialSource.file, ''); assert.equal(manifest.authMode, 'auth'); assert.deepEqual(manifest.quotaAuthModes, ['auth']);
    assert.equal(manifest.inheritQueryUrl, workspaceProviders[provider]);
    for (const key of ['apiUrl', 'authCallUrl', 'refreshUrl']) assert.equal(manifest[key], undefined);
    for (const source of [manifest.credentialSource, ...manifest.credentialSource.alternatives]) {
      assert.equal(typeof source.tokenPath, 'string');
      for (const path of Object.values(source.contextPaths)) assert.equal(typeof path, 'string');
    }
    const { output, args } = run(provider, fixture);
    assert.equal(output.error, null); assert.equal(output.stale, false);
    assert.equal(normalizeUsage(output).windows.length, output.windows.length);
    assert.equal(args[0], '-q'); assert.equal(args[args.indexOf('--proto') + 1], '=https');
    assert.equal(args[args.indexOf('--connect-timeout') + 1], '3'); assert.equal(args[args.indexOf('--max-time') + 1], '12');
    assert(!args.includes('-L') && !args.includes('--location'));
    assert(!JSON.stringify(args).includes('sourceB') && !JSON.stringify(args).includes('cookieB') && !JSON.stringify(args).includes('attacker.invalid'));
    const url = new URL(args.at(-1));
    assert.equal(url.origin, new URL(workspaceProviders[provider]).origin); assert.equal(url.pathname, new URL(workspaceProviders[provider]).pathname);
    assert.equal(args[args.indexOf('-X') + 1], provider === 'joycode' ? 'POST' : 'GET');
    for (const window of output.windows) {
      assert.equal(window.period, 'balance'); assert.match(window.label, /余额$/);
      for (const key of ['limit', 'used_percentage', 'resets_at']) assert.equal(window[key], undefined);
    }
    if (provider === 'joycode') {
      assert(args.includes('ptkey: snapshotA')); assert(args.includes('logintype: PIN_JD_CLOUD')); assert(args.includes('tenant: %E7%A7%9F%E6%88%B7A'));
      assert.equal(args[args.indexOf('--data-binary') + 1], '{}');
      assert.equal(url.searchParams.get('appid'), 'joycode_ide'); assert.equal(url.searchParams.get('functionId'), 'get_newpoint_ide'); assert.match(url.searchParams.get('sign'), /^[a-f0-9]{64}$/);
      const material = `${url.searchParams.get('appid')}&${url.searchParams.get('functionId')}&${url.searchParams.get('t')}`;
      // Independently recompute signature with the shipped public client constant.
      const source = readFileSync(join(hud, 'catalog-workspace-provider.mjs'), 'utf8');
      const key = source.match(/const JOY_SIGN_KEY = '([^']+)'/)[1];
      assert.equal(url.searchParams.get('sign'), createHmac('sha256', key).update(material).digest('hex'));
      assert.equal(output.windows[0].amount, 80);
    } else {
      assert(args.includes('Authorization: Bearer snapshotA')); assert(!args.includes('--data-binary'));
      if (provider === 'zcode-start') { assert(args.includes('X-Device-Mid: deviceA')); assert(args.includes('User-Agent: ZCode/3.17.2')); assert.equal(output.windows.length, 1); assert.equal(output.windows[0].amount, 50); }
      if (provider.startsWith('autoclaw')) {
        for (const header of ['X-Auth-Appid: 100003', 'X-Product: autoclaw', 'X-Version: 1.18.1', 'X-Channel: AutoClaw4', 'Origin: http://localhost:18432', 'Referer: http://localhost:18432/']) assert(args.includes(header));
        const timestamp = args.find(x => x.startsWith('X-Auth-TimeStamp: ')).split(': ')[1];
        const key = readFileSync(join(hud, 'catalog-workspace-provider.mjs'), 'utf8').match(/const AUTO_APP_KEY = '([^']+)'/)[1];
        assert(args.includes('X-Auth-Sign: ' + createHash('md5').update(`100003&${timestamp}&${key}`).digest('hex')));
        assert.equal(output.windows[0].amount, 100);
        assert(!args.some(x => /signin|checkin|task/i.test(x)));
      }
    }
    if (provider !== 'joycode') {
      const bearer = run(provider, fixture, { auth: { queryKey: 'Bearer snapshotA' } });
      assert.equal(bearer.output.error, null);
      assert(bearer.args.includes('Authorization: Bearer snapshotA'));
    }
    assert.equal(run(provider, fixture, { stdoutOnly: false }).output.error, null);
    for (const auth of [{ queryKey: '' }, { queryKey: undefined }, { authMode: 'apikey' }]) { const r = run(provider, fixture, { auth }); assert.equal(r.output.error, 'no-auth'); assert.equal(r.args, null); }
    const expired = run(provider, fixture, { auth: { tokenhudAuthContext: { device: 'deviceA', expiresAt: 1 } } }); assert.equal(expired.output.error, 'auth'); assert.equal(expired.args, null);
    const jwt = 'e30.' + Buffer.from('{"exp":1}').toString('base64url') + '.sig';
    assert.equal(run(provider, fixture, { auth: { queryKey: jwt } }).output.error, 'auth');
    for (const status of [401, 403, 302, 429, 500]) { const r = run(provider, fixture, { status }); assert(r.output.error); assert.equal(r.output.stale, true); }
    assert.equal(run(provider, fixture, { exit: 28 }).output.error, 'network');
    for (const invalid of ['invalid-json', { code: 0, data: {} }, { code: 0, data: { total_balance: null, available_points: false, usageItems: [{ remain: '' }] } }]) assert.equal(run(provider, invalid).output.error, 'parse');
    assert.equal(run(provider, { code: 401 }).output.error, 'auth');
    const zero = structuredClone(fixture);
    if (provider === 'zcode-start') zero.data.balances[0].remaining_units = 0;
    else if (provider === 'joycode') zero.data.usageItems[0].remain = 0;
    else if (provider === 'raccoon') zero.data.available_points = 0;
    else zero.data.total_balance = 0;
    const z = run(provider, zero).output; assert.equal(z.error, null); assert.equal(z.windows[0].amount, 0);
  }
  assert.equal(run('zcode-start', fixtures['zcode-start'], { auth: { tokenhudAuthContext: {} } }).output.error, 'no-context');
  assert.equal(parseWorkspaceUsage('raccoon', { available_points: null }), null);
  assert.equal(parseWorkspaceUsage('autoclaw', { total_balance: 'garbage' }), null);
  console.log(`PASS catalog workspace providers: ${scenarios} offline real-wrapper scenarios across 5 types`);
} finally {
  assert(temp.startsWith(join(tmpdir(), 'tokenhud-workspace-')) && resolve(temp) !== resolve(tmpdir()));
  rmSync(temp, { recursive: true, force: true });
}
