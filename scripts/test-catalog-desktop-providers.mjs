#!/usr/bin/env node
// Offline only: execute the shipped wrappers with fake curl and an isolated HOME.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, copyFileSync, rmSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { desktopProviders, parseCursor, parseWorkBuddy, parseMiMo, parseTrae, instant, cursorCookie } from '../Sources/TokenHUD/mjs/catalog-desktop-provider.mjs';
const root = dirname(dirname(fileURLToPath(import.meta.url))), homes = [];
const token = 'test.' + Buffer.from(JSON.stringify({ sub: 'auth0|USER_A', exp: 4102444800 })).toString('base64url') + '.signature';
const epoch = 1893456000;
const fixtures = {
 cursor: { planUsage: { autoPercentUsed: 0, apiPercentUsed: 100, totalPercentUsed: 20 }, billingCycleEnd: String(epoch * 1000), spendLimitUsage: { individualUsed: 0, individualLimit: 2000 } },
 'workbuddy-cn': { code: 0, data: { IsPaidUser: true, CreditGroups: [{ Kind: 'plan_base', CycleTotalCapacity: 500, CycleUsedCapacity: 0 }, { Kind: 'extra', CycleTotalCapacity: 50, CycleUsedCapacity: 50 }], Packages: [{ CycleRemainCapacity: 0 }] } },
 workbuddy: { code: 0, data: { CreditGroups: [{ Kind: 'plan_base', CycleTotalCapacity: 100, CycleUsedCapacity: 0 }] } },
 'xiaomi-mimo-desktop': { code: 0, data: { percent: 100, resetDate: '2030-01-01 08:00:00' } },
 'trae-cn': { user_entitlement_pack_list: [{ entitlement_base_info: { quota: { credits_limit: 100 }, end_time: epoch }, usage: { credits_amount: 0 } }] },
 trae: { user_entitlement_pack_list: [{ entitlement_base_info: { quota: { basic_usage_limit: 20, bonus_usage_limit: 5 }, end_time: epoch }, usage: { basic_usage_amount: 0, bonus_usage_amount: 0 } }] },
};
const context = id => id === 'cursor' ? { authId: 'auth0|USER_A', teamId: 'TEAM_A' }
 : id.startsWith('workbuddy') ? { userId: 'USER_A', domain: new URL(desktopProviders[id].host).host, enterpriseId: 'ENTERPRISE_A' }
 : id === 'xiaomi-mimo-desktop' ? { xiaomiCredentials: JSON.stringify({ region: 'SGP', base: 'https://mimo-server-sgp.xiaomimimo.com/api', userId: 'USER_A', passToken: 'DO_NOT_SEND_PASS_TOKEN' }) }
 : { userId: 'USER_A', deviceId: 'DEVICE_A', machineId: 'MACHINE_A', region: 'SG' };
function setup(id) {
 const home = mkdtempSync(join(tmpdir(), 'tokenhud-desktop-test-')); homes.push(home);
 const hud = join(home, '.claude/hud'); mkdirSync(hud, {recursive:true});
 copyFileSync(join(root, 'Sources/TokenHUD/mjs/catalog-desktop-provider.mjs'), join(hud, 'catalog-desktop-provider.mjs'));
 const external = join(home, 'global-auth.json'); writeFileSync(external, JSON.stringify({access:'OLD_ACCOUNT_B',accessToken:'OLD_ACCOUNT_B',queryCookie:'OLD_COOKIE_B'}));
 // Also seed customary global paths: none may be discovered by the new adapter.
 mkdirSync(join(home,'.cursor'),{recursive:true}); writeFileSync(join(home,'.cursor/auth.json'),JSON.stringify({accessToken:'OLD_ACCOUNT_B'}));
 const snapshot = join(home, 'snapshot.json');
 const queryKey = id === 'xiaomi-mimo-desktop' ? JSON.stringify({serviceToken:'APP_SESSION_A',userId:'USER_A',cUserId:'CUSER_A'}) : token;
 writeFileSync(snapshot,JSON.stringify({authMode:'auth',queryKey,tokenhudAuthContext:context(id),authCredentialFile:external,queryAPIKey:'OLD_KEY_B',queryCookie:'OLD_COOKIE_B'}));
 const curl = join(home,'curl');
 writeFileSync(curl,`#!${process.execPath}\nconst fs=require('node:fs');const args=process.argv.slice(2);fs.appendFileSync(process.env.CURL_LOG,JSON.stringify(args)+'\\n');const url=args[args.indexOf('--url')+1];const path=new URL(url).pathname;const codes=JSON.parse(process.env.HTTP_CODES||'{}');const code=codes[path]||process.env.HTTP_CODE||'200';if(code==='EXIT7')process.exit(7);const responses=JSON.parse(process.env.RESPONSES||'{}');const body=Object.hasOwn(responses,path)?responses[path]:JSON.parse(process.env.RESPONSE);process.stdout.write((process.env.RAW_RESPONSE||JSON.stringify(body))+'\\n'+code);`,{mode:0o755});
 return {id,home,hud,snapshot,external,curl};
}
function run(s, response=fixtures[s.id], extra={}) {
 const before=readFileSync(s.snapshot,'utf8'), externalBefore=readFileSync(s.external,'utf8');
 const responses={
  '/aiserver.v1.DashboardService/GetPlanInfo':{planInfo:{planName:'Pro'}},
  '/aiserver.v1.DashboardService/GetHardLimit':{hardLimit:20},
  '/aiserver.v1.DashboardService/GetUsageLimitStatusAndActiveGrants':{activeGrants:[]},
  '/api/user/xiaomi/subscription/self':{code:0,data:{current:{title:'MiMo Pro'}}},
  '/billing/meter/get-enterprise-user-usage':{code:0,data:{}},
 };
 const result=spawnSync('/bin/zsh',[join(root,'Sources/TokenHUD/providers',s.id,'fetch.sh')],{env:{...process.env,HOME:s.home,CLAUDE_CONFIG_DIR:join(s.home,'.claude'),TOKENHUD_NODE:process.execPath,TOKENHUD_AUTH_FILE:s.snapshot,TOKENHUD_HUD_DIR:s.hud,TOKENHUD_CACHE_FILE:join(s.home,'cache.json'),TOKENHUD_CURL:s.curl,CURL_LOG:join(s.home,'curl.log'),RESPONSE:JSON.stringify(response),RESPONSES:JSON.stringify(responses),...extra},encoding:'utf8',timeout:26000});
 assert.equal(result.status,0,result.stderr||result.error?.message);assert.equal(result.stderr,'');
 assert.equal(readFileSync(s.snapshot,'utf8'),before,'selected snapshot must remain unchanged');
 assert.equal(readFileSync(s.external,'utf8'),externalBefore,'external auth must remain unchanged');
 assert.equal(readFileSync(join(s.home,'.cursor/auth.json'),'utf8'),JSON.stringify({accessToken:'OLD_ACCOUNT_B'}));
 return JSON.parse(result.stdout);
}
function calls(s){return existsSync(join(s.home,'curl.log'))?readFileSync(join(s.home,'curl.log'),'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];}
const urlOf=args=>args[args.indexOf('--url')+1];
const bodyOf=args=>args.includes('--data-binary')?JSON.parse(args[args.indexOf('--data-binary')+1]):undefined;
function snapshot(s,value){writeFileSync(s.snapshot,JSON.stringify(value));}
after(()=>{for(const home of homes){const target=resolve(home);assert.ok(target.startsWith(resolve(tmpdir())+'/tokenhud-desktop-test-'));rmSync(target,{recursive:true,force:true});}});
for(const id of Object.keys(desktopProviders)){
 test(`${id}: real wrapper uses only selected snapshot and fixed read-only requests`,()=>{
  const s=setup(id),out=run(s),requests=calls(s);assert.equal(out.error,null);assert.equal(out.stale,false);assert.ok(out.windows.length);assert.ok(out.windows.some(w=>w.used_percentage===0||w.amount===0));
  assert.ok(requests.some(args=>urlOf(args)===desktopProviders[id].host+desktopProviders[id].path));
  const wire=JSON.stringify(requests);assert.ok(!wire.includes('OLD_ACCOUNT_B'));assert.ok(!wire.includes('OLD_COOKIE_B'));assert.ok(!wire.includes('OLD_KEY_B'));assert.ok(!wire.includes('DO_NOT_SEND_PASS_TOKEN'));
  assert.ok(!JSON.stringify(out).includes(token));assert.ok(!JSON.stringify(out).includes('APP_SESSION_A'));
  for(const args of requests){assert.equal(args[0],'-q');assert.ok(args.includes('--connect-timeout')&&args.includes('--max-time'));assert.ok(args.includes('=https'));assert.ok(!args.includes('-L')&&!args.includes('--location'));assert.ok(!/refresh|signin|checkin|claim|apiKey\/raw|chat\/completions|exchange|\/sts/.test(urlOf(args)));}
  const primary=requests.find(args=>urlOf(args).endsWith(desktopProviders[id].path));
  if(id==='cursor'){assert.ok(primary.includes('Authorization: Bearer '+token));assert.ok(primary.includes('x-cursor-team-id: TEAM_A'));assert.ok(primary.includes('Connect-Protocol-Version: 1'));assert.deepEqual(bodyOf(primary),{});}
  if(id.startsWith('workbuddy')){for(const h of ['Authorization: Bearer '+token,'X-User-Id: USER_A','X-Enterprise-Id: ENTERPRISE_A','X-Tenant-Id: ENTERPRISE_A','X-Product: SaaS','X-IDE-Type: WorkBuddy'])assert.ok(primary.includes(h));assert.deepEqual(bodyOf(primary),{});}
  if(id.startsWith('trae')){for(const h of ['Authorization: Cloud-IDE-JWT '+token,'X-Cloudide-Token: '+token,'x-uid: USER_A','x-device-id: DEVICE_A','x-machine-id: MACHINE_A'])assert.ok(primary.includes(h));assert.deepEqual(bodyOf(primary),id==='trae-cn'?{require_usage:true,req_source:0}:{});}
  if(id==='xiaomi-mimo-desktop'){assert.ok(primary.includes('Cookie: serviceToken=APP_SESSION_A; userId=USER_A; cUserId=CUSER_A'));assert.equal(bodyOf(primary),undefined);assert.equal(primary[primary.indexOf('-X')+1],'GET');assert.ok(!wire.includes('Authorization:'));}
 });
 test(`${id}: missing counters and transport failures delegate last-good retention without exposing bodies`,()=>{
  const s=setup(id),good=run(s);const missing=run(s,{});assert.equal(missing.error,'parse');assert.equal(missing.windows,undefined);assert.equal(missing.stale,true);
  for(const [status,error]of [['401','auth'],['403','auth'],['429','ratelimit'],['302','network'],['500','network'],['EXIT7','network']]){const out=run(s,{error:'RESPONSE_SECRET'},{HTTP_CODE:status});assert.equal(out.error,error);assert.equal(out.windows,undefined);assert.ok(!JSON.stringify(out).includes('RESPONSE_SECRET'));}
  assert.equal(run(s,{}, {RAW_RESPONSE:'invalid json RESPONSE_SECRET'}).error,'parse');
 });
 test(`${id}: missing Auth, APIKey, expired, and wrong source cannot fall back to old global B`,()=>{
  const s=setup(id);snapshot(s,{authMode:'apikey',queryKey:'KEY'});assert.equal(run(s).error,'no-query');assert.equal(calls(s).length,0);
  snapshot(s,{authCredentialFile:s.external});assert.ok(['no-auth','encrypted','session'].includes(run(s).error));assert.equal(calls(s).length,0);
  snapshot(s,{queryKey:token,tokenhudAuthContext:{...context(id),expiresAt:'1'}});assert.equal(run(s).error,'auth');assert.equal(calls(s).length,0);
  snapshot(s,{queryKey:token,tokenhudAuthContext:{sourceProvider:'OTHER_ACCOUNT_PROVIDER'}});assert.equal(run(s).error,'region');assert.equal(calls(s).length,0);
 });
 test(`${id}: manifest is Auth-only, default-off creation, no fictitious model call`,()=>{
  const m=JSON.parse(readFileSync(join(root,'Sources/TokenHUD/providers',id,'manifest.json')));assert.equal(m.autoCreateDefault,false);assert.equal(m.authMode,'auth');assert.equal(m.quotaMode,'script');assert.deepEqual(m.quotaAuthModes,['auth']);assert.equal(m.credentialSource.file,'');assert.ok(m.credentialSource.tokenPath);for(const field of ['authCallUrl','apiKeyCallUrl','refreshUrl','testModel'])assert.equal(m[field],undefined);
 });
}
test('Cursor derives dashboard cookie from same JWT, does not follow redirects, does not mix selected teams',()=>{
 const s=setup('cursor');snapshot(s,{queryKey:token,tokenhudAuthContext:{}});
 const enterprise={membershipType:'enterprise',individualUsage:{overall:{enabled:true,used:0,limit:2500}},billingCycleEnd:'2030-01-01T00:00:00Z'};
 const out=run(s,{}, {RESPONSES:JSON.stringify({'/api/usage-summary':enterprise})});assert.equal(out.error,null);assert.equal(out.windows[0].amount,0);assert.equal(out.windows[0].limit,25);
 const dashboard=calls(s).find(args=>urlOf(args)==='https://cursor.com/api/usage-summary');assert.ok(dashboard.includes('Cookie: '+cursorCookie(token)));assert.ok(!dashboard.some(a=>a.startsWith('Authorization:')));assert.equal(bodyOf(dashboard),undefined);
 const team=setup('cursor');assert.equal(run(team,{}).error,'parse');assert.ok(calls(team).every(a=>new URL(urlOf(a)).hostname==='api2.cursor.sh'));
 snapshot(team,{queryKey:token,tokenhudAuthContext:{teamId:'TEAM_B',authId:'OTHER_SUB'}});const n=calls(team).length;assert.equal(run(team).error,'region');assert.equal(calls(team).length,n);
});
test('Cursor merged usage, USD grant expiry and zero remain distinct from missing quota',()=>{
 const data={planUsage:{totalPercentUsed:0},billingCycleEnd:epoch*1000};const info={isMerged:true,planInfo:{includedUsagePeriod:2}};
 const out=parseCursor(data,info,{}, {activeGrants:[{totalCents:100,remainingCents:0,expiresAtMs:epoch*1000,allowedClientTypes:['glass']}]});
 assert.equal(out.windows[0].period,'7d');assert.equal(out.windows[1].amount,1);assert.equal(out.windows[1].limit,1);assert.equal(out.windows[1].expires_at,epoch);assert.equal(out.windows[1].resets_at,undefined);assert.match(out.windows[1].label,/glass only/);assert.equal(parseCursor({planUsage:{}}),null);
});
test('WorkBuddy empty summary uses only enterprise meter; balance is remaining amount without limit',()=>{
 for(const id of ['workbuddy','workbuddy-cn']){const s=setup(id);const out=run(s,{code:0,data:{}},{RESPONSES:JSON.stringify({'/billing/meter/get-enterprise-user-usage':{code:0,data:{limitNum:200,credit:0,cycleStartTime:'2029-12-31 08:00:00',cycleResetTime:'2030-01-01 08:00:00'}}})});assert.equal(out.error,null);assert.equal(out.windows[0].period,'86400s');assert.equal(out.windows[0].resets_at,epoch);assert.equal(calls(s).length,2);}
 const zero=parseWorkBuddy({Packages:[{CycleRemainCapacity:0}]}).windows[0];assert.equal(zero.period,'balance');assert.equal(zero.amount,0);assert.equal(zero.limit,undefined);assert.equal(zero.used_percentage,undefined);assert.equal(parseWorkBuddy({CreditGroups:[{CycleTotalCapacity:100}]}),null);
});
test('MiMo reads existing same-source sessions in all supported regions, never starts passToken login',()=>{
 const s=setup('xiaomi-mimo-desktop');snapshot(s,{queryKey:JSON.stringify({serviceToken:'RU_SESSION_A'}),tokenhudAuthContext:{xiaomiCredentials:JSON.stringify({region:'RU',base:'https://mimo-server-ru.xiaomimimo.com/api',passToken:'NEVER_USED'})}});assert.equal(run(s).error,null);assert.ok(calls(s).every(a=>new URL(urlOf(a)).hostname==='mimo-server-ru.xiaomimimo.com'));
 const n=calls(s).length;snapshot(s,{queryKey:JSON.stringify({passToken:'PASS_A'}),tokenhudAuthContext:{}});assert.equal(run(s).error,'session');assert.equal(calls(s).length,n);
 snapshot(s,{queryKey:JSON.stringify({serviceToken:'A'}),tokenhudAuthContext:{xiaomiCredentials:JSON.stringify({region:'SGP',base:'https://evil.example/api'})}});assert.equal(run(s).error,'region');assert.equal(calls(s).length,n);
 assert.equal(parseMiMo({}, {percent:100,resetDate:'2030-01-01'}).windows[0].resets_at,epoch-28800);
 assert.equal(parseMiMo({}, {percent:100}),null);assert.equal(parseMiMo({}, {percent:null,resetDate:'2030-01-01 08:00:00'}),null);assert.equal(parseMiMo({}, {percent:0,resetDate:'2030-01-01 08:00:00'}).windows[0].used_percentage,100);
});
test('Trae global US selects exact regional host; both regions require genuine usage counters',()=>{
 const s=setup('trae');snapshot(s,{queryKey:token,tokenhudAuthContext:{...context('trae'),region:'US'}});assert.equal(run(s).error,null);assert.equal(urlOf(calls(s)[0]),'https://api-us-east.trae.ai/trae/api/v1/pay/user_current_entitlement_list');
 const cn=setup('trae-cn');snapshot(cn,{queryKey:token,tokenhudAuthContext:{...context('trae-cn'),authHost:'https://growsg-normal.trae.ai'}});assert.equal(run(cn).error,'region');assert.equal(calls(cn).length,0);
 for(const isCN of [false,true])assert.equal(parseTrae({user_entitlement_pack_list:[{entitlement_base_info:{quota:isCN?{credits_limit:100}:{basic_usage_limit:20}},usage:{}}]},isCN),null);
 assert.equal(parseTrae({user_entitlement_pack_list:[]},true),null);assert.equal(instant('2030-01-01 08:00:00','+08:00'),epoch);assert.equal(instant(null),null);
});
test('WorkBuddy Magpie source aliases cannot send a CN token to the international endpoint',()=>{
 for(const [id,sourceProvider]of [['workbuddy-cn','workbuddy'],['workbuddy','workbuddy-ai']]){
  const s=setup(id);snapshot(s,{queryKey:token,tokenhudAuthContext:{userId:'USER_A',sourceProvider}});assert.equal(run(s).error,null);assert.ok(calls(s).every(a=>urlOf(a).startsWith(desktopProviders[id].host+'/')));
 }
 const s=setup('workbuddy');snapshot(s,{queryKey:token,tokenhudAuthContext:{userId:'USER_A',sourceProvider:'workbuddy'}});assert.equal(run(s).error,'region');assert.equal(calls(s).length,0);
 snapshot(s,{queryKey:token,tokenhudAuthContext:{userId:'USER_A',sourceProvider:'workbuddy',domain:'copilot.tencent.com'}});assert.equal(run(s).error,'region');assert.equal(calls(s).length,0);
});
test('Cursor explicitly disabled on-demand does not become a positive remaining allowance',()=>{
 for(const spendLimitUsage of [{individualUsed:0,individualLimit:2000},{limitType:'team',individualUsed:0,pooledUsed:0,pooledLimit:2000}]){
  const out=parseCursor({planUsage:{totalPercentUsed:20},spendLimitUsage},{},{noUsageBasedAllowed:true,hardLimit:20});assert.ok(out.windows.every(w=>w.label!=='On-demand'));
 }
});
test('confirmed host auth.json entry pointers select only the requested provider record',()=>{
 const entries={cursor:'cursor','workbuddy-cn':'workbuddy',workbuddy:'workbuddy-ai','xiaomi-mimo-desktop':'mimo-app','trae-cn':'trae-cn',trae:'trae-global'};
 const at=(o,path)=>path.startsWith('/')?path.slice(1).split('/').reduce((v,k)=>v?.[k.replace(/~1/g,'/').replace(/~0/g,'~')],o):path.split('.').reduce((v,k)=>v?.[k],o);
 for(const[id,entry]of Object.entries(entries)){
  const s=setup(id),key=id==='xiaomi-mimo-desktop'?JSON.stringify({serviceToken:'APP_SESSION_A'}):token;
  const auth={type:'oauth',access:key,uid:'USER_A',deviceId:'DEVICE_A',machineId:'MACHINE_A',region:id==='xiaomi-mimo-desktop'?'SGP':'SG',domain:id.startsWith('workbuddy')?new URL(desktopProviders[id].host).host:undefined,refresh:id==='xiaomi-mimo-desktop'?JSON.stringify({region:'SGP',base:'https://mimo-server-sgp.xiaomimimo.com/api'}):'REFRESH_A_UNUSED'};
  const main={[entry]:auth,oldProvider:{type:'oauth',access:'OLD_ACCOUNT_B'}};
  const manifest=JSON.parse(readFileSync(join(root,'Sources/TokenHUD/providers',id,'manifest.json')));
  const formats=[manifest.credentialSource,...(manifest.credentialSource.alternatives||[])];
  const selected=formats.find(f=>typeof at(main,f.tokenPath)==='string'&&Object.entries(f.requiredValues||{}).every(([path,value])=>at(main,path)===value));
  assert.equal(selected.tokenPath,`/${entry}/access`);
  const authContext=Object.fromEntries(Object.entries(selected.contextPaths||{}).map(([key,path])=>[key,at(main,path)]).filter(([,value])=>typeof value==='string'));
  snapshot(s,{queryKey:at(main,selected.tokenPath),tokenhudAuthContext:authContext});assert.equal(run(s).error,null);assert.ok(!JSON.stringify(calls(s)).includes('OLD_ACCOUNT_B'));assert.ok(!JSON.stringify(calls(s)).includes('REFRESH_A_UNUSED'));
 }
});
test('snapshot header injection and malformed context stop before curl',()=>{
 const s=setup('cursor');snapshot(s,{queryKey:'A\r\nAuthorization: BAD',tokenhudAuthContext:{}});assert.equal(run(s).error,'no-auth');assert.equal(calls(s).length,0);
 snapshot(s,{queryKey:token,tokenhudAuthContext:{teamId:'A\r\nBad: B'}});assert.equal(run(s).error,'no-auth');assert.equal(calls(s).length,0);
});
