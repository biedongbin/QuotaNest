#!/usr/bin/env node
// Offline adapter tests: fake curl, isolated HOME, selected snapshot A vs global B.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, copyFileSync, rmSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { authProviders } from '../Sources/TokenHUD/mjs/catalog-auth-provider.mjs';
import { parseAuthUsage, instant } from '../Sources/TokenHUD/mjs/auth-usage-parsers.mjs';
const root = dirname(dirname(fileURLToPath(import.meta.url))), homes = [];
const seconds = 1794000000;
const fixtures = {
 'claude-code': { five_hour: { utilization: 0 }, seven_day_sonnet: { utilization: 34, resets_at: seconds * 1000 } },
 antigravity: { groups: [{ displayName: 'Shared', buckets: [{ bucketId: 'a', window: 'weekly', remainingFraction: 0, resetTime: seconds }, { bucketId: 'b', window: '12h', remainingFraction: 1 }] }] },
 'gemini-cli': { buckets: [{ modelId: 'gemini-pro', tokenType: 'INPUT', remainingFraction: 0, resetTime: new Date(seconds * 1000).toISOString() }, { modelId: 'gemini-flash', remainingFraction: 1 }] },
 'github-copilot': { quota_reset_date: '2026-12-01', quota_snapshots: { premium_interactions: { entitlement: '300', quota_remaining: '0' }, chat: { entitlement: 50, quota_remaining: 50 } } },
 devin: { userStatus: { planStatus: { dailyQuotaRemainingPercent: 0, weeklyQuotaRemainingPercent: '100', dailyQuotaResetAtUnix: String(seconds) } } },
 'grok-cli': { config: { creditUsagePercent: 0, currentPeriod: { type: 'custom', start: seconds - 43200, end: seconds }, prepaidBalance: 0 } },
};
function setup(provider) {
 const home = mkdtempSync(join(tmpdir(), 'tokenhud-catalog-auth-test-')); homes.push(home);
 const hud = join(home, '.claude/hud'); mkdirSync(hud, {recursive:true});
 for (const name of ['catalog-auth-provider.mjs','auth-usage-parsers.mjs']) copyFileSync(join(root,'Sources/TokenHUD/mjs',name),join(hud,name));
 const global = join(home,'global-auth.json'); writeFileSync(global,JSON.stringify({access_token:'GLOBAL_B',api_key:'GLOBAL_B',project_id:'GLOBAL_PROJECT_B'}));
 const snapshot = join(home,'snapshot.json'); writeFileSync(snapshot,JSON.stringify({authMode:'auth',queryKey:'SNAPSHOT_A',tokenhudAuthContext:{projectId:'PROJECT_A',userId:'USER_A'},authCredentialFile:global}));
 const curl = join(home,'curl');
 writeFileSync(curl,`#!${process.execPath}\nimport fs from 'node:fs';\nconst args=process.argv.slice(2);fs.appendFileSync(process.env.CURL_LOG,JSON.stringify(args)+'\\n');\nconst url=args[args.indexOf('--url')+1];\nconst code=process.env.HTTP_CODE || '200';\nif(code==='EXIT7')process.exit(7);\nprocess.stdout.write((url.includes('loadCodeAssist') ? process.env.DISCOVERY : process.env.RESPONSE)+'\\n'+code);\n`,{mode:0o755});
 return {home,hud,global,snapshot,curl,provider};
}
function run(state, body = fixtures[state.provider], extra = {}) {
 const before = readFileSync(state.snapshot,'utf8'), globalBefore = readFileSync(state.global,'utf8');
 const result = spawnSync('/bin/zsh',[join(root,'Sources/TokenHUD/providers',state.provider,'fetch.sh')],{
  env:{...process.env, HOME:state.home, CLAUDE_CONFIG_DIR:join(state.home,'.claude'), TOKENHUD_NODE:process.execPath,TOKENHUD_AUTH_FILE:state.snapshot,TOKENHUD_HUD_DIR:state.hud,TOKENHUD_CACHE_FILE:join(state.home,'cache.json'),TOKENHUD_CURL:state.curl,CURL_LOG:join(state.home,'curl.log'),RESPONSE:JSON.stringify(body),DISCOVERY:JSON.stringify({cloudaicompanionProject:{id:'DISCOVERED_A'}}),...extra},encoding:'utf8',timeout:20000,
 });
 assert.equal(result.status,0,result.stderr || result.error?.message);
 assert.equal(readFileSync(state.snapshot,'utf8'),before,'must not write selected auth snapshot');
 assert.equal(readFileSync(state.global,'utf8'),globalBefore,'must not write external auth');
 return JSON.parse(result.stdout);
}
function calls(state) { return existsSync(join(state.home,'curl.log')) ? readFileSync(join(state.home,'curl.log'),'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : []; }
after(()=>{ for(const home of homes) { assert.ok(resolve(home).startsWith(join(tmpdir(),'tokenhud-catalog-auth-test-'))); rmSync(home,{recursive:true,force:true}); } });
for (const provider of Object.keys(authProviders)) {
 test(`${provider}: actual fetch wrapper uses only snapshot A and exact quota protocol`,()=>{
  const state=setup(provider), cache=run(state), [args]=calls(state);
  assert.equal(cache.error,null);assert.equal(cache.stale,false);assert.ok(cache.windows.length>=1);
  assert.equal(args[args.indexOf('--url')+1],authProviders[provider].url);
  assert.ok(args.includes('--connect-timeout') && args.includes('--max-time'));
  assert.equal(args[0],'-q','disable user curl config');assert.ok(!args.includes('-L')&&!args.includes('--location'));
  assert.ok(args.join('\n').includes('SNAPSHOT_A'));assert.ok(!args.join('\n').includes('GLOBAL_B'));
  assert.ok(!args.join('\n').includes('$TOKEN$'));assert.ok(!JSON.stringify(cache).includes('SNAPSHOT_A'));
  if(provider==='devin') {
   assert.ok(!args.some(v=>v.startsWith('Authorization:')));
   assert.ok(args.includes('Connect-Protocol-Version: 1'));
   assert.deepEqual(JSON.parse(args[args.indexOf('--data-binary')+1]),{metadata:{ideName:'chisel',ideVersion:'3000.10.21',apiKey:'SNAPSHOT_A',locale:'en',os:'darwin',extensionVersion:'3000.10.21',clientName:'chisel'}});
  } else {
   assert.ok(args.includes(`Authorization: ${provider==='github-copilot'?'token':'Bearer'} SNAPSHOT_A`));
  }
  if(['antigravity','gemini-cli'].includes(provider)) assert.deepEqual(JSON.parse(args[args.indexOf('--data-binary')+1]),{project:'PROJECT_A'});
  if(provider==='claude-code') assert.ok(args.includes('anthropic-beta: oauth-2025-04-20'));
  if(provider==='grok-cli') {assert.ok(args.includes('x-userid: USER_A'));assert.ok(args.includes('x-xai-token-auth: '+['xai','grok','cli'].join('-')));}
 });
 test(`${provider}: missing quota stays unknown and HTTP errors delegate last-good retention to the native engine`,()=>{
  const state=setup(provider), good=run(state);
  const missing=run(state,{});assert.equal(missing.error,'parse');assert.equal(missing.windows,undefined);assert.equal(missing.stale,true);
  for(const [code,error] of [['401','auth'],['403','auth'],['429','ratelimit'],['302','network'],['500','network'],['EXIT7','network']]) {
   const cache=run(state,{access_token:'DO_NOT_LEAK'}, {HTTP_CODE:code});assert.equal(cache.error,error);assert.equal(cache.windows,undefined);assert.ok(!JSON.stringify(cache).includes('DO_NOT_LEAK'));
  }
 });
 test(`${provider}: API Key quota unsupported, no snapshot never falls back to global auth`,()=>{
  const state=setup(provider);writeFileSync(state.snapshot,JSON.stringify({authMode:'apikey',queryKey:'KEY'}));
  assert.equal(run(state).error,'no-query');assert.equal(calls(state).length,0);
  writeFileSync(state.snapshot,JSON.stringify({authCredentialFile:state.global}));assert.equal(run(state).error,'no-auth');assert.equal(calls(state).length,0);
  assert.equal(run(state,{}, {TOKENHUD_AUTH_FILE:''}).error,'no-auth');assert.equal(calls(state).length,0);
 });
 test(`${provider}: manifests advertise Auth quota without unimplemented call endpoints`,()=>{
  const manifest=JSON.parse(readFileSync(join(root,'Sources/TokenHUD/providers',provider,'manifest.json')));
  assert.equal(manifest.autoCreateDefault,false);assert.deepEqual(manifest.quotaAuthModes,['auth']);assert.ok(manifest.credentialSource.tokenPath);assert.equal(manifest.authCallUrl,undefined);assert.equal(manifest.refreshUrl,undefined);
 });
}
test('Gemini missing project performs loadCodeAssist discovery without onboarding or auth write',()=>{
 const state=setup('gemini-cli');writeFileSync(state.snapshot,JSON.stringify({queryKey:'A',tokenhudAuthContext:{}}));
 assert.equal(run(state).error,null);const requests=calls(state);assert.equal(requests.length,2);
 assert.ok(requests[0].includes('https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist'));
 assert.deepEqual(JSON.parse(requests[0][requests[0].indexOf('--data-binary')+1]),{metadata:{ideType:9,platform:2,pluginType:2}});
 assert.deepEqual(JSON.parse(requests[1][requests[1].indexOf('--data-binary')+1]),{project:'DISCOVERED_A'});
 assert.ok(!JSON.stringify(requests).includes('onboard'));
});
test('Gemini supports providerSpecificData project context and no invented project',()=>{
 const state=setup('gemini-cli');writeFileSync(state.snapshot,JSON.stringify({queryKey:'A',tokenhudAuthContext:{providerProjectId:'PSD_A'}}));
 assert.equal(run(state).error,null);assert.equal(calls(state).length,1);
 assert.deepEqual(JSON.parse(calls(state)[0][calls(state)[0].indexOf('--data-binary')+1]),{project:'PSD_A'});
 writeFileSync(state.snapshot,JSON.stringify({queryKey:'A'}));assert.equal(run(state,{}, {DISCOVERY:'{}'}).error,'no-auth');
});
test('Antigravity missing project stops before requesting quota',()=>{
 const state=setup('antigravity');writeFileSync(state.snapshot,JSON.stringify({queryKey:'A'}));assert.equal(run(state).error,'no-auth');assert.equal(calls(state).length,0);
});
test('zero, seconds/milliseconds/RFC3339, and actual service window duration remain distinct',()=>{
 assert.equal(instant(seconds),seconds);assert.equal(instant(seconds*1000),seconds);assert.equal(instant(new Date(seconds*1000).toISOString()),seconds);assert.equal(instant(null),null);
 for(const [provider,data] of Object.entries(fixtures)) assert.ok(parseAuthUsage(provider,data).windows.some(w=>w.used_percentage===0 || w.amount===0));
 const gemini=parseAuthUsage('gemini-cli',fixtures['gemini-cli']).windows;assert.equal(gemini[0].period,undefined);assert.equal(gemini[1].resets_at,undefined);assert.equal(gemini[0].used_percentage,100);
 const ag=parseAuthUsage('antigravity',fixtures.antigravity).windows;assert.deepEqual(ag.map(w=>w.period),['7天','12h']);
 const grok=parseAuthUsage('grok-cli',fixtures['grok-cli']).windows;assert.equal(grok[0].period,'12小时');assert.equal(grok[1].unit,'credits');
 assert.equal(parseAuthUsage('claude-code',{five_hour:{}}),null);
 assert.equal(parseAuthUsage('gemini-cli',{buckets:[{modelId:'x',remainingFraction:null}]}),null);
});
test('Claude extra windows, scoped models, dollar pool, and extra credits remain separate',()=>{
 const cache=parseAuthUsage('claude-code',{seven_day_new_model:{utilization:9},iguana_necktie:{utilization:4},limits:[{kind:'weekly_scoped',percent:17,scope:{model:{display_name:'New model'}}}],extra_usage:{is_enabled:true,used_credits:3,monthly_limit:20},pool:{limit_dollars:7,used_dollars:0}});
 assert.equal(cache.windows.length,5);assert.equal(cache.windows.find(w=>w.label==='iguana_necktie').period,undefined);assert.equal(cache.windows.find(w=>w.label==='pool').unit,'USD');assert.equal(cache.windows.find(w=>w.label==='extra_usage').unit,'credits');assert.ok(cache.windows.every(w=>w.resets_at===undefined));
});
test('Copilot never turns missing quota into unlimited; free allowance supports exact counts',()=>{
 assert.equal(parseAuthUsage('github-copilot',{quota_snapshots:{chat:{}}}),null);
 const cache=parseAuthUsage('github-copilot',{monthly_quotas:{chat:50},limited_user_quotas:{chat:0},limited_user_reset_date:'2026-12-01'});
 assert.equal(cache.windows[0].amount,50);assert.equal(cache.windows[0].used_percentage,100);
});
test('Grok explicit totalUsed aliases preserve actual known usage',()=>{
 for(const field of ['totalUsed','total_used']) {
  const cache=parseAuthUsage('grok-cli',{config:{monthlyLimit:100,[field]:25}});
  assert.equal(cache.windows[0].amount,25);assert.equal(cache.windows[0].used_percentage,25);assert.equal(cache.windows[0].unit,'credits');
 }
});
test('Grok billing errors and malformed responses never call paid chat or alternate endpoints',()=>{
 const state=setup('grok-cli');assert.equal(run(state,{error:'billing unavailable'}).error,'parse');
 assert.equal(calls(state).length,1);assert.ok(calls(state)[0].includes(authProviders['grok-cli'].url));
 assert.equal(run(state,{}, {RESPONSE:'not json'}).error,'parse');
});
