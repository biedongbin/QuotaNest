#!/usr/bin/env node
// Offline wire-contract tests through each installed fetch.sh, with isolated accounts.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, copyFileSync, rmSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { parseQoder, parseKiro, parseZed, parseMiniMaxCode, timestamp, signedMiniMaxRequest } from '../Sources/TokenHUD/mjs/catalog-account-provider.mjs';
const root = dirname(dirname(fileURLToPath(import.meta.url))), homes = [];
const end = 1900000000, profile = 'arn:aws:codewhisperer:us-east-1:123456789012:profile/PROFILE_A';
const paths = {
 qoder: 'https://openapi.qoder.sh/api/v2/quota/usage',
 'qoder-cn': 'https://openapi.qoder.com.cn/api/v2/quota/usage',
 kiro: 'https://codewhisperer.us-east-1.amazonaws.com/',
 'minimax-code-cn': 'https://agent.minimaxi.com/matrix/api/v1/user/get_user_extra_info',
 'minimax-code': 'https://agent.minimax.io/matrix/api/v1/user/get_user_extra_info',
 zed: 'https://cloud.zed.dev/client/users/me',
};
const sourceId = id => ({'minimax-code-cn':'minimax-code','minimax-code':'minimax-code-global'})[id] || id;
const quota = {userQuota:{total:100,used:0,remaining:100,unit:'credits'},orgResourcePackage:{total:0,used:0,remaining:0,unit:'requests'},expiresAt:end*1000};
const kiro = {usageBreakdownList:[{resourceType:'CREDIT',unit:'credits',currentUsageWithPrecision:0,usageLimitWithPrecision:50,freeTrialInfo:{currentUsageWithPrecision:2,usageLimitWithPrecision:10,freeTrialExpiry:end}}],nextDateReset:end,subscriptionInfo:{subscriptionTitle:'Pro'}};
const zed = {plan:{plan_v3:'zed_pro',subscription_period:{ended_at:new Date(end*1000).toISOString()},usage:{edit_predictions:{used:0,limit:{limited:2000}},model_requests:{used:10,limit:0}}}};
const member = {data:{has_token_plan:true,op_group_id:'GROUP_A',token_plan_tier:'Plus',token_plan_expires_at:end,op_credit_summary:{total_remaining_amount:'0'}}};
const plan = {base_resp:{status_code:0},model_remains:[{model_name:'general',current_interval_remaining_percent:100,start_time:end-43200,end_time:end,current_weekly_remaining_percent:0,weekly_start_time:end-604800,weekly_end_time:end}]};
const defaultResponses = {
 '/api/v2/quota/usage':quota,'/api/v1/jobToken/exchange':{token:'jt-DERIVED_A',refresh_token:'NEVER_WRITE_REFRESH'},
 '/':kiro,'/client/users/me':zed,'/v1/api/user/info':{data:{userInfo:{realUserID:'DISCOVERED_USER_A'}}},
 '/matrix/api/v1/user/get_user_extra_info':{data:{workspaces:[{workspace_type:0,workspace_id:101}]}},
 '/matrix/api/v1/commerce/get_membership_info':member,'/v1/api/openplatform/coding_plan/remains':plan,
};
const manifest = id => JSON.parse(readFileSync(join(root,'Sources/TokenHUD/providers',id,'manifest.json')));
// Model the core's format selection independently: choose one entire declared format.
const at = (obj,path) => path.split('.').reduce((a,k)=>a?.[k],obj);
function snapshotFor(id, raw) {
 const s=manifest(id).credentialSource;
 const f=[s,...s.alternatives||[]].find(f=>Object.entries(f.requiredValues||{}).every(([k,v])=>at(raw,k)===v)&&typeof at(raw,f.tokenPath)==='string'&&at(raw,f.tokenPath).trim());
 assert.ok(f,'fixture must be an advertised complete credential format');
 return {authMode:'auth',queryKey:at(raw,f.tokenPath),tokenhudAuthContext:Object.fromEntries(Object.entries(f.contextPaths||{}).map(([k,p])=>[k,at(raw,p)]).filter(([,v])=>typeof v==='string'))};
}
function setup(id, override) {
 const home=mkdtempSync(join(tmpdir(),'tokenhud-account-test-'));homes.push(home);
 const hud=join(home,'.claude/hud');mkdirSync(hud,{recursive:true});
 copyFileSync(join(root,'Sources/TokenHUD/mjs/catalog-account-provider.mjs'),join(hud,'catalog-account-provider.mjs'));
 const other=join(home,'other-account.json');writeFileSync(other,JSON.stringify({accessToken:'GLOBAL_B',providerSpecificData:{userId:'USER_B',region:'cn'}}));
 const raw=override||{provider:sourceId(id),accessToken:'ACCESS_A',expiresAt:'2030-03-17T17:46:40Z',providerSpecificData:{userId:'USER_A',systemId:'SYSTEM_A',authMethod:'api_key',profileArn:profile,realUserID:'REAL_USER_A',...(id==='kiro'?{region:'us-east-1'}:id.startsWith('qoder')?{region:id==='qoder-cn'?'cn':'intl'}:{})}};
 const snapshot=join(home,'snapshot.json');writeFileSync(snapshot,JSON.stringify({...snapshotFor(id,raw),authCredentialFile:other}));
 const curl=join(home,'fake-curl.cjs');
 writeFileSync(curl,`#!${process.execPath}\nconst fs=require('node:fs'); const a=process.argv.slice(2);fs.appendFileSync(process.env.CURL_LOG,JSON.stringify(a)+'\\n'); const u=new URL(a[a.indexOf('--url')+1]); if(process.env.HTTP_CODE==='EXIT7')process.exit(7); const map=JSON.parse(process.env.RESPONSES);process.stdout.write((process.env.BAD_JSON?'not json':JSON.stringify(map[u.pathname]??{}))+'\\n'+(JSON.parse(process.env.PATH_STATUS||'{}')[u.pathname]||process.env.HTTP_CODE||'200'));\n`,{mode:0o755});
 return {id,home,hud,other,snapshot,curl,cache:join(home,'cache.json'),log:join(home,'calls.jsonl')};
}
function run(s, responses={}, env={}) {
 const before=readFileSync(s.snapshot,'utf8'),other=readFileSync(s.other,'utf8');
 const r=spawnSync('/bin/zsh',[join(root,'Sources/TokenHUD/providers',s.id,'fetch.sh')],{encoding:'utf8',timeout:22000,env:{...process.env,HOME:s.home,CLAUDE_CONFIG_DIR:join(s.home,'.claude'),TOKENHUD_NODE:process.execPath,TOKENHUD_HUD_DIR:s.hud,TOKENHUD_AUTH_FILE:s.snapshot,TOKENHUD_CACHE_FILE:s.cache,TOKENHUD_CURL:s.curl,CURL_LOG:s.log,RESPONSES:JSON.stringify({...defaultResponses,...responses}),...env}});
 assert.equal(r.status,0,r.stderr||r.error?.message);assert.equal(readFileSync(s.snapshot,'utf8'),before);assert.equal(readFileSync(s.other,'utf8'),other);
 const out=JSON.parse(r.stdout);assert.ok(!r.stdout.includes('ACCESS_A')&&!r.stdout.includes('GLOBAL_B')&&!r.stdout.includes('jt-DERIVED_A')&&!r.stdout.includes('NEVER_WRITE_REFRESH'));
 return out;
}
const calls=s=>existsSync(s.log)?readFileSync(s.log,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
const url=a=>a[a.indexOf('--url')+1];
const header=(a,k)=>a.filter((_,i)=>a[i-1]==='-H').find(h=>h.toLowerCase().startsWith(k.toLowerCase()+': '))?.slice(k.length+2);
const body=a=>a.includes('--data-binary')?JSON.parse(a[a.indexOf('--data-binary')+1]):undefined;
const setSnapshot=(s,v)=>writeFileSync(s.snapshot,JSON.stringify(v));
after(()=>{for(const home of homes){assert.ok(resolve(home).startsWith(join(tmpdir(),'tokenhud-account-test-')));rmSync(home,{recursive:true,force:true});}});
for(const id of Object.keys(paths)) {
 test(`${id}: manifest, selected source context, real wrapper, exact quota protocol and zero`,()=>{
  const m=manifest(id);assert.equal(m.autoCreateDefault,false);assert.equal(m.authMode,'auth');assert.deepEqual(m.quotaAuthModes,['auth']);assert.equal(m.credentialSource.file,'');assert.equal(m.refreshUrl,undefined);assert.equal(m.authCallUrl,undefined);
  const s=setup(id),out=run(s),requests=calls(s);assert.equal(out.error,null);assert.equal(out.stale,false);assert.ok(out.windows.length);assert.ok(out.windows.some(w=>w.amount===0||w.used_percentage===0));
  assert.equal(new URL(url(requests[0])).origin+new URL(url(requests[0])).pathname,paths[id]);
  for(const a of requests){assert.equal(a[0],'-q');assert.ok(a.includes('--max-time')&&a.includes('--connect-timeout'));assert.ok(a.includes('--proto')&&a.includes('=https'));assert.ok(!a.includes('-L')&&!a.includes('--location'));assert.ok(!JSON.stringify(a).includes('GLOBAL_B'));assert.ok(!url(a).includes('/chat')&&!url(a).includes('/reset'));assert.ok(header(a,'Authorization')?.includes('ACCESS_A'));}
  if(id.startsWith('qoder')) {assert.equal(requests.length,1);assert.equal(header(requests[0],'Authorization'),'Bearer ACCESS_A');assert.equal(out.windows[0].unit,'credits');assert.equal(out.windows[1].unit,'requests');assert.equal(out.expires_at,end);assert.ok(out.windows.every(w=>w.resets_at===undefined));}
  if(id==='kiro'){assert.equal(requests[0][requests[0].indexOf('-X')+1],'POST');assert.equal(header(requests[0],'Content-Type'),'application/x-amz-json-1.0');assert.equal(header(requests[0],'x-amz-target'),'AmazonCodeWhispererService.GetUsageLimits');assert.equal(header(requests[0],'tokentype'),'API_KEY');assert.deepEqual(body(requests[0]),{origin:'AI_EDITOR',profileArn:profile,resourceType:'AGENTIC_REQUEST'});assert.equal(out.windows[0].resets_at,end);assert.equal(out.windows[1].expires_at,end);assert.equal(out.windows[1].resets_at,undefined);assert.equal(out.windows[0].unit,'credits');}
  if(id==='zed'){assert.equal(header(requests[0],'Authorization'),'USER_A ACCESS_A');assert.equal(header(requests[0],'x-zed-system-id'),'SYSTEM_A');assert.equal(out.windows.length,1);assert.equal(out.windows[0].limit,2000);assert.equal(out.windows[0].unit,'requests');assert.equal(out.windows[0].resets_at,end);}
  if(id.startsWith('minimax')) {assert.equal(requests.length,3);assert.deepEqual(body(requests[0]),{});assert.deepEqual(body(requests[1]),{workspace_id:101});assert.equal(header(requests[2],'X-Group-Id'),'GROUP_A');assert.equal(header(requests[2],'yy'),undefined);assert.equal(out.windows[0].amount,0);assert.equal(out.windows[0].unit,'credits');assert.equal(out.windows[1].period,'12h');assert.equal(out.windows[2].used_percentage,100);assert.equal(out.expires_at,end);}
 });
 test(`${id}: missing fields and all HTTP/network errors remain unknown/stale without auth writes`,()=>{
  const s=setup(id),good=run(s);const empty=Object.fromEntries(Object.keys(defaultResponses).map(k=>[k,{}]));
  const missing=run(s,empty);assert.equal(missing.error,'parse');assert.equal(missing.stale,true);assert.equal(missing.windows,undefined);
  for(const [code,expected] of [['401','auth'],['403','auth'],['429','ratelimit'],['302','network'],['500','network'],['EXIT7','network']]){const out=run(s,{}, {HTTP_CODE:code});assert.equal(out.error,expected);assert.equal(out.windows,undefined);}
  assert.equal(run(s,{}, {BAD_JSON:'1'}).error,'parse');
 });
 test(`${id}: no query credential fallback, wrong source/expiry/context rejected before curl`,()=>{
  const s=setup(id);setSnapshot(s,{authMode:'auth',apiKey:'GLOBAL_B',authCredentialFile:s.other});assert.equal(run(s).error,'no-auth');assert.equal(calls(s).length,0);
  setSnapshot(s,{authMode:'apikey',queryKey:'ACCESS_A'});assert.equal(run(s).error,'no-query');
  setSnapshot(s,{queryKey:'ACCESS_A',tokenhudAuthContext:{sourceProvider:'WRONG_REGION'}});assert.equal(run(s).error,'region');
  setSnapshot(s,{queryKey:'ACCESS_A',tokenhudAuthContext:{expiresAt:'2000-01-01T00:00:00Z'}});assert.equal(run(s).error,'auth');
  setSnapshot(s,{queryKey:'ACCESS_A',tokenhudAuthContext:{userId:'A\r\nInjected: yes'}});assert.equal(run(s).error,'no-auth');
  assert.equal(run(s,{}, {TOKENHUD_AUTH_FILE:''}).error,'no-auth');assert.equal(calls(s).length,0);
 });
}
for(const id of ['qoder','qoder-cn']) {
 test(`${id}: PAT exchanges on correct regional host, no Authorization on exchange, job only in memory`,()=>{
  const s=setup(id,{provider:sourceId(id),apiKey:'pt-PAT_A',providerSpecificData:{region:id==='qoder-cn'?'cn':'intl'}});const out=run(s),[exchange,usage]=calls(s);assert.equal(out.error,null);
  assert.equal(new URL(url(exchange)).origin,new URL(paths[id]).origin);assert.equal(new URL(url(exchange)).pathname,'/api/v1/jobToken/exchange');assert.equal(header(exchange,'Authorization'),undefined);assert.equal(header(exchange,'Cosy-Version'),'1.0.0');assert.equal(header(exchange,'Cosy-ClientType'),'5');assert.deepEqual(body(exchange),{personal_token:'pt-PAT_A'});assert.equal(header(usage,'Authorization'),'Bearer jt-DERIVED_A');assert.equal(calls(s).length,2);assert.ok(!readFileSync(s.cache,'utf8').includes('pt-PAT_A'));
  assert.equal(run(s,{'/api/v1/jobToken/exchange':{}}).error,'parse');
 });
 test(`${id}: region context cannot leak a token to the other regional host`,()=>{
  const s=setup(id);setSnapshot(s,{queryKey:'ACCESS_A',tokenhudAuthContext:{region:id==='qoder-cn'?'intl':'cn'}});assert.equal(run(s).error,'region');assert.equal(calls(s).length,0);
 });
}
test('Kiro supports full native/external formats, never mixes PSD and native context',()=>{
 const raw={accessToken:'NATIVE_A',authMethod:'builder-id',region:'us-east-1',profileArn:profile,providerSpecificData:{profileArn:'OTHER_B'}};
 const s=setup('kiro',raw);assert.equal(run(s).error,null);assert.equal(body(calls(s)[0]).profileArn,profile);
 const ext=setup('kiro',{auth_method:'external_idp',access_token:'EXTERNAL_A',profile_arn:profile,region:'us-east-1'});assert.equal(run(ext).error,null);assert.equal(header(calls(ext)[0],'TokenType'),'EXTERNAL_IDP');
 const selected=snapshotFor('kiro',{...raw,provider:'kiro',providerSpecificData:{authMethod:'api_key',profileArn:profile,region:'us-east-1'}});assert.equal(selected.tokenhudAuthContext.authMethod,'api_key');
 setSnapshot(s,{queryKey:'ACCESS_A',tokenhudAuthContext:{authMethod:'idc',region:'eu-west-1',profileArn:profile}});assert.equal(run(s).error,null);assert.equal(url(calls(s).at(-1)),'https://codewhisperer.us-east-1.amazonaws.com/');
 setSnapshot(s,{queryKey:'ACCESS_A',tokenhudAuthContext:{authMethod:'api_key',profileArn:'arn:aws:codewhisperer:eu-west-1:123456789012:profile/A'}});assert.equal(run(s).error,'region');
});
test('Zed N counts work; P plan-only, token billing only, and missing userId stay unknown',()=>{
 assert.equal(parseZed({plan:{plan_v3:'zed_pro'}}),null);assert.equal(parseZed({plan:{usage:{model_requests:{used:0,limit:0}}}}),null);
 assert.equal(parseZed({plan:{usage:{edit_predictions:{limit:2000}}}}),null);
 assert.equal(parseZed({plan:{usage:{edit_predictions:{used:7,limit:'unlimited'}}}}).windows[0].unlimited,true);
 const s=setup('zed');assert.equal(run(s,{'/client/users/me':{plan:{plan_v3:'zed_pro'}}}).error,'parse');
 setSnapshot(s,{queryKey:'ACCESS_A',tokenhudAuthContext:{}});const n=calls(s).length;assert.equal(run(s).error,'no-auth');assert.equal(calls(s).length,n);
});
test('MiniMax signatures match independent wire formula, identity stays same-account, only permitted methods',()=>{
 const md5=s=>createHash('md5').update(s).digest('hex');
 for(const id of ['minimax-code-cn','minimax-code']) {
  const s=setup(id);const snap=JSON.parse(readFileSync(s.snapshot));delete snap.tokenhudAuthContext.realUserID;setSnapshot(s,snap);assert.equal(run(s).error,null);
  const requests=calls(s);assert.equal(requests.length,4);assert.equal(new URL(url(requests[0])).pathname,'/v1/api/user/info');
  for(const [index,a] of requests.entries()) {
   if(index===3)continue;
   const u=new URL(url(a)),ts=header(a,'x-timestamp'),milliseconds=u.searchParams.get('unix');
   assert.equal(header(a,'yy'),md5(`${encodeURIComponent(u.pathname+u.search)}_${a.includes('--data-binary')?a[a.indexOf('--data-binary')+1]:'{}'}${md5(milliseconds)}ooui`));
   assert.match(header(a,'x-signature'),/^[a-f0-9]{32}$/);assert.equal(Number(ts),Math.floor(Number(milliseconds)/1000));
   assert.equal(u.searchParams.get('user_id'),index===0?'0':'DISCOVERED_USER_A');assert.equal(u.searchParams.get('lang'),id.endsWith('-cn')?'zh':'en');
  }
 }
});
test('MiniMax partial requests retain fresh same-account credits, but auth failures stay explicit',()=>{
 for(const id of ['minimax-code-cn','minimax-code']) {
  const s=setup(id);
  const updated={data:{...member.data,op_credit_summary:{total_remaining_amount:'17'}}};
  const partial=run(s,{'/matrix/api/v1/commerce/get_membership_info':updated},{PATH_STATUS:JSON.stringify({'/v1/api/openplatform/coding_plan/remains':'500'})});
  assert.equal(partial.error,null);assert.equal(partial.partial,true);assert.equal(partial.windows.length,1);assert.equal(partial.windows[0].amount,17);assert.equal(partial.stale,false);assert.ok(partial.message);
  const malformed=run(s,{'/matrix/api/v1/commerce/get_membership_info':updated,'/v1/api/openplatform/coding_plan/remains':{}});assert.equal(malformed.partial,true);assert.equal(malformed.windows[0].amount,17);
  const recovered=run(s,{}, {PATH_STATUS:JSON.stringify({'/matrix/api/v1/user/get_user_extra_info':'500'})});assert.equal(recovered.error,null);assert.equal(recovered.partial,true);assert.deepEqual(body(calls(s).at(-2)),{});
  const workspace={data:{workspaces:[{workspace_type:0,workspace_id:101,...member.data,op_credit_summary:{total_remaining_amount:'23'}}]}};
  const retained=run(s,{'/matrix/api/v1/user/get_user_extra_info':workspace},{PATH_STATUS:JSON.stringify({'/matrix/api/v1/commerce/get_membership_info':'500'})});assert.equal(retained.error,null);assert.equal(retained.partial,true);assert.equal(retained.windows[0].amount,23);
  const denied=run(s,{'/matrix/api/v1/commerce/get_membership_info':updated},{PATH_STATUS:JSON.stringify({'/v1/api/openplatform/coding_plan/remains':'401'})});assert.equal(denied.error,'auth');assert.equal(denied.stale,true);
 }
});
test('MiniMax x-signature GET and POST match fixed independent protocol reference vectors',()=>{
 const config={host:'https://agent.minimaxi.com',lang:'zh'};
 const get=signedMiniMaxRequest(config,'/v1/api/user/info','TOKEN','USER',undefined,1900000000123);
 const post=signedMiniMaxRequest(config,'/matrix/api/v1/commerce/get_membership_info','TOKEN','USER',{workspace_id:101},1900000000123);
 assert.equal(get.headers['x-signature'],'7b861adf40b6992006eb0b56e4044041');
 assert.equal(post.headers['x-signature'],'612b77e5eb341014e0bb25439a37e6ff');
});
test('Missing, zero, units, expiry and reset are distinct in every parser',()=>{
 for(const parse of [parseQoder,parseKiro,parseZed,parseMiniMaxCode])assert.equal(parse({}),null);
 assert.equal(parseQoder({userQuota:{total:100}}),null);assert.equal(parseQoder({userQuota:{total:20,remaining:20,unit:'tokens'}}).windows[0].amount,0);
 assert.equal(parseKiro({usageBreakdownList:[{resourceType:'CREDIT',usageLimitWithPrecision:10}]}),null);
 assert.equal(parseMiniMaxCode({has_token_plan:false}),null);assert.equal(parseMiniMaxCode({opcredit_balance:'0'}).windows[0].amount,0);
 const invalid=parseMiniMaxCode({}, {model_remains:[{model_name:'general',current_interval_remaining_percent:null,current_weekly_status:3,current_weekly_remaining_percent:50}]});assert.equal(invalid,null);
 assert.equal(timestamp(end),end);assert.equal(timestamp(end*1000),end);assert.equal(timestamp(new Date(end*1000).toISOString()),end);assert.equal(timestamp(null),null);
});
