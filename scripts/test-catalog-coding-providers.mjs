#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, chmodSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { codingProviders, parseMiniMax, parseKimi, parseCodeBuddy, parseCommandCode, parseZai, resetSeconds } from '../Sources/TokenHUD/mjs/catalog-coding-provider.mjs';

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const temp = mkdtempSync(join(tmpdir(), 'tokenhud-coding-test-'));
let checks = 0;
function check(fn) { fn(); checks++; }
const at = 1794000000;
const fixtures = {
 zai: { success: true, data: { level: 'pro', limits: [
  { type: 'TOKENS_LIMIT', unit: 3, number: 5, percentage: 0, nextResetTime: at * 1000 },
  { type: 'TOKENS_LIMIT', unit: 6, percentage: 75 },
  { type: 'TOKENS_LIMIT', unit: 3, number: 1 },
  { type: 'TIME_LIMIT', percentage: 10 },
 ] } },
 minimax: { base_resp: { status_code: 0 }, model_remains: [
  { model_name: 'general', current_interval_remaining_percent: 100, start_time: at - 18000, end_time: at,
    current_interval_total_count: 0, current_interval_usage_count: 0,
    current_weekly_remaining_percent: 25, weekly_end_time: at * 1000 },
  { model_name: 'video', current_interval_total_count: 10, current_interval_usage_count: 3, current_interval_remaining_percent: 70, start_time: at - 86400, end_time: at },
  { model_name: 'image', current_interval_status: 2, current_interval_total_count: 0, current_interval_remaining_percent: 99 },
  { model_name: 'unavailable', current_interval_status: 3, current_weekly_status: 3, current_interval_remaining_percent: 100 },
 ] },
 kimi: { user: { membership: { level: 'pro' } }, usage: { limit: '100', remaining: '75', resetTime: at },
 limits: [{ window: { duration: 300, timeUnit: 'TIME_UNIT_MINUTE' }, detail: { limit: '10', remaining: '10', resetTime: at * 1000 } }],
 usages: { limit_month_total: { used_ratio: 0.2, reset_time: '2026-11-07T00:00:00.123Z' }, limit_month_code: { used_ratio: 0.9 } } },
 buddy: { code: 0, data: { Response: { Data: { Accounts: [
  { PackageName: 'Pro', CycleStartTime: (at - 30 * 86400) * 1000, CycleEndTime: at * 1000, DeductionEndTime: (at + 90 * 86400) * 1000,
    CycleCapacityUsedPrecise: '0', CycleCapacityUsed: 99, CycleCapacitySizePrecise: '500', CapacityUsedPrecise: '70', CapacitySizePrecise: '100' },
  { CycleEndTime: at * 1000, DeductionEndTime: at * 1000, CapacityUsedPrecise: '2.5', CapacitySizePrecise: '10', CycleCapacityUsed: 9, CycleCapacitySize: 9 },
 ] } } } },
 command: { credits: { planId: 'individual-ultra', monthlyCredits: '0', purchasedCredits: '5.25', freeCredits: 2 },
 windowLimits: { fiveHour: { used: '0', cap: '10', resetAt: at * 1000 }, weekly: { used: 12, cap: 40, resetAt: at } } },
 subscriptions: { success: true, data: { planId: 'individual-ultra', currentPeriodEnd: '2026-12-01T00:00:00Z' } },
};
try {
 const fake = join(temp, 'fake-curl');
 writeFileSync(fake, `#!${process.execPath}\nconst fs=require('node:fs');const args=process.argv.slice(2);fs.appendFileSync(process.env.TEST_REQUESTS,JSON.stringify(args)+'\\n');const url=args[args.indexOf('--url')+1];const fixtures=JSON.parse(fs.readFileSync(process.env.TEST_FIXTURES,'utf8'));const payload=fixtures[url];if(payload===undefined){process.stderr.write('Unexpected fixture URL');process.exit(7);}process.stdout.write(JSON.stringify(payload)+'\\n'+(process.env.TEST_HTTP_CODE||'200'));\n`);
 chmodSync(fake, 0o755);
 const source = join(root, 'Sources/TokenHUD/mjs/catalog-coding-provider.mjs');
 const hud = join(temp, 'hud'); mkdirSync(hud);
 writeFileSync(join(hud, 'catalog-coding-provider.mjs'), readFileSync(source));
 const authA = join(temp, 'snapshot-A.json'), authB = join(temp, 'key-B.json');
 const bytesA = Buffer.from(JSON.stringify({ queryKey: 'fixture-key-A', refreshApiKey: 'fixture-key-B', queryCookie: 'legacy-cookie-B', authFile: authB, apiUrl: 'https://wrong.invalid', headers: { Authorization: 'Bearer fixture-key-B' } }, null, 2));
 const bytesB = Buffer.from('{"queryKey":"fixture-key-B"}\n');
 writeFileSync(authA, bytesA); writeFileSync(authB, bytesB);
 for (const [id, config] of Object.entries(codingProviders)) {
  const requests = join(temp, `${id}-requests.jsonl`), fixtureFile = join(temp, `${id}-fixtures.json`), cache = join(temp, `${id}-cache.json`);
  const fixture = id === 'zai-coding' ? fixtures.zai : id.startsWith('minimax') ? fixtures.minimax : id.startsWith('kimi') ? fixtures.kimi : id.startsWith('codebuddy') ? fixtures.buddy : fixtures.command;
  const replies = { [config.url]: fixture };
  if(id === 'commandcode') replies['https://api.commandcode.ai/alpha/billing/subscriptions'] = fixtures.subscriptions;
  writeFileSync(fixtureFile, JSON.stringify(replies));
  const env = { ...process.env, TOKENHUD_HUD_DIR: hud, TOKENHUD_AUTH_FILE: authA, USAGE_AUTH_FILE: authB, TOKENHUD_CACHE_FILE: cache, TOKENHUD_NODE: process.execPath, TOKENHUD_CURL: fake, TOKENHUD_STDOUT_ONLY: '1', TOKENHUD_QUERY_URL: 'https://wrong.invalid', TEST_REQUESTS: requests, TEST_FIXTURES: fixtureFile };
  const run = overrides => {
   const child = spawnSync('/bin/zsh', [join(root, `Sources/TokenHUD/providers/${id}/fetch.sh`)], { env: { ...env, ...overrides }, encoding: 'utf8' });
   assert.equal(child.status, 0, `${id}: ${child.stderr}`);
   return JSON.parse(child.stdout);
  };
  const result = run({});
  check(() => { assert.equal(result.error, null, id); assert.equal(result.stale, false); assert.ok(result.generatedAt > 0); assert.ok(result.windows.length > 0); assert.equal(existsSync(cache), false); });
  const invocations = readFileSync(requests, 'utf8').trim().split('\n').map(JSON.parse);
  check(() => {
   assert.equal(invocations.length, id === 'commandcode' ? 2 : 1);
   for (const args of invocations) {
    assert.equal(args[0], '-q'); assert.ok(!args.includes('-L')); assert.ok(!args.includes('--location'));
    assert.ok(args.includes('--max-time')); assert.ok(args.includes('--connect-timeout'));
    assert.ok(args.includes(`Authorization: ${config.bare ? '' : 'Bearer '}fixture-key-A`));
    assert.ok(!args.join(' ').includes('fixture-key-B')); assert.ok(!args.join(' ').includes('legacy-cookie-B'));
    assert.ok(!args.join(' ').includes('wrong.invalid'));
    for (const [key, value] of Object.entries(config.headers || {})) assert.ok(args.includes(`${key}: ${value}`));
    if (config.method === 'POST') { assert.equal(args[args.indexOf('-X') + 1], 'POST'); assert.equal(args[args.indexOf('--data') + 1], '{}'); }
   }
  });
  const manifest = JSON.parse(readFileSync(join(root, `Sources/TokenHUD/providers/${id}/manifest.json`)));
  check(() => { assert.equal(manifest.autoCreateDefault, false); assert.equal(manifest.authMode, 'apikey'); assert.deepEqual(manifest.quotaAuthModes, ['apikey']); assert.equal(manifest.queryAuth, 'bearer'); assert.equal(manifest.quotaMode, 'script'); assert.equal(manifest.inheritQueryUrl, config.url); assert.equal(manifest.testModel, ''); assert.ok(manifest.refreshUrl.startsWith('https://')); });
  check(() => assert.equal(run({ TEST_HTTP_CODE: '403' }).error, 'auth'));
  check(() => assert.equal(run({ TEST_HTTP_CODE: '302' }).error, 'network'));
  check(() => assert.equal(run({ TOKENHUD_AUTH_FILE: '', USAGE_AUTH_FILE: authB }).error, 'no-auth'));
  const raw = join(temp, `${id}-legacy.json`); writeFileSync(raw, JSON.stringify({ refreshApiKey: 'fixture-key-B', queryCookie: 'legacy-B', headers: { Authorization: 'Bearer fixture-key-B' } }));
  check(() => assert.equal(run({ TOKENHUD_AUTH_FILE: raw }).error, 'no-auth'));
  run({ TOKENHUD_STDOUT_ONLY: '0' });
  check(() => { assert.equal(JSON.parse(readFileSync(cache)).error, null); assert.deepEqual(readFileSync(authA), bytesA); assert.deepEqual(readFileSync(authB), bytesB); });
 }
 check(() => { const p = parseZai(fixtures.zai); assert.equal(p.five_hour.used_percentage, 0); assert.equal(p.five_hour.resets_at, at); assert.equal(p.seven_day.resets_at, null); assert.equal(p.windows.length, 3); });
 check(() => { const p = parseMiniMax(fixtures.minimax); assert.equal(p.five_hour.used_percentage, 0); assert.equal(p.five_hour.resets_at, at); assert.equal(p.seven_day.used_percentage, 75); const video=p.windows.find(w=>w.unit==='videos'); assert.equal(video.amount,3); assert.equal(video.limit,10); assert.equal(video.period,'24h'); assert.equal(p.windows.find(w=>w.label.startsWith('image')).used_percentage,100); assert.ok(!p.windows.some(w=>w.label.startsWith('unavailable'))); });
 check(() => { const body={base_resp:{status_code:0},model_remains:[{model_name:'video',current_interval_total_count:10,current_interval_usage_count:7,current_interval_remaining_percent:70}]}; assert.equal(parseMiniMax(body,'coding_plan').windows[0].amount,3); assert.equal(parseMiniMax(body,'token_plan').windows[0].amount,undefined); delete body.model_remains[0].current_interval_remaining_percent; assert.equal(parseMiniMax(body,'coding_plan').windows[0].amount,3); assert.equal(parseMiniMax(body,'token_plan').windows[0].amount,7); });
 check(() => { const p=parseKimi(fixtures.kimi); assert.equal(p.windows.length,3); assert.equal(p.five_hour.used_percentage,0); assert.equal(p.seven_day.used_percentage,25); assert.equal(p.monthly.used_percentage,20); assert.equal(p.five_hour.resets_at,at); assert.equal(p.seven_day.resets_at,at); assert.equal(p.windows[1].amount,25); assert.equal(p.windows[1].unit,'count'); assert.equal(p.monthly.resets_at,Date.parse('2026-11-07T00:00:00Z')/1000); });
 check(() => { const p=parseKimi({usages:{limit5h:{usedRatio:0,resetAt:String(at)},limitMonthCode:{usedRatio:0.5}}}); assert.equal(p.five_hour.used_percentage,0); assert.equal(p.monthly.used_percentage,50); assert.equal(p.monthly.resets_at,null); });
 check(() => { const p=parseCodeBuddy(fixtures.buddy); assert.equal(p.windows[0].amount,0); assert.equal(p.windows[0].limit,500); assert.equal(p.windows[0].period,'month'); assert.equal(p.windows[1].amount,2.5); assert.equal(p.windows[1].limit,10); assert.equal(p.windows[1].period,'expiry'); assert.equal(p.windows[1].unit,'credits'); });
 check(() => { const p=parseCommandCode(fixtures.command,fixtures.subscriptions); assert.equal(p.five_hour.used_percentage,0); assert.equal(p.seven_day.used_percentage,30); const monthly=p.windows.find(w=>w.label==='月剩余余额'); assert.equal(monthly.period,'balance'); assert.equal(monthly.amount,0); assert.equal(monthly.limit,undefined); assert.equal(monthly.used_percentage,undefined); assert.equal(monthly.unit,'credits'); assert.ok(!JSON.stringify(p).includes('USD')); assert.ok(!JSON.stringify(p).includes('CNY')); assert.equal(p.windows.find(w=>w.label.startsWith('购买余额')).resets_at,null); assert.equal(p.windows.find(w=>w.label.startsWith('购买余额')).amount,5.25); });
 check(() => { const p=parseCommandCode({credits:{monthlyCredits:12},windowLimits:{fiveHour:{used:0}}}); assert.equal(p.windows[0].limit,undefined); assert.equal(p.windows[0].used_percentage,undefined); assert.equal(p.windows[1].resets_at,null); });
 check(() => { assert.deepEqual(parseKimi({}).windows,[]); assert.deepEqual(parseCommandCode({}).windows,[]); assert.deepEqual(parseMiniMax({base_resp:{status_code:0},model_remains:[{model_name:'general'}]}).windows,[]); assert.throws(()=>parseMiniMax({base_resp:{status_code:1004}})); assert.throws(()=>parseZai({success:false})); });
 check(() => { for(const v of [at, at*1000, String(at), String(at*1000)]) assert.equal(resetSeconds(v),at); for(const v of [null,undefined,'',0,false,'bogus']) assert.equal(resetSeconds(v),null); });
 check(() => { const p=parseMiniMax({base_resp:{status_code:0},model_remains:[{model_name:'MiniMax-M2.5',current_interval_remaining_percent:80},{model_name:'MiniMax-M2.7',current_interval_remaining_percent:20}]}); assert.equal(p.windows.length,2); assert.equal(p.windows[0].used_percentage,20); assert.equal(p.windows[1].used_percentage,80); });
 check(() => { const p=parseMiniMax({base_resp:{status_code:0},model_remains:[{model_name:'general',current_interval_remaining_percent:80,current_weekly_status:3},{model_name:'video',current_weekly_total_count:35,current_weekly_usage_count:14,current_weekly_remaining_percent:60}]}); assert.equal(p.seven_day,undefined); assert.equal(p.windows.length,2); assert.equal(p.windows[1].used_percentage,40); });
 check(() => { const p=parseKimi({limits:[{window:{},detail:{limit:10,used:1}},{window:{},detail:{limit:20,used:2}}]}); assert.equal(p.windows.length,2); assert.equal(p.windows[0].amount,1); assert.equal(p.windows[1].amount,2); });
 console.log(`PASS catalog coding providers: ${checks} checks; 8 real wrappers with fake cURL; no vendor requests`);
} finally {
 // temp is the exact directory returned by mkdtemp above, under the OS temp root.
 assert.ok(temp.startsWith(join(tmpdir(), 'tokenhud-coding-test-')));
 rmSync(temp, { recursive: true, force: true });
}
