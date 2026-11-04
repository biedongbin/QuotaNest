#!/usr/bin/env node
// OpenCode Zen only: real rendered wrapper, isolated HOME, fake curl.
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, rmSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { rateProviders, parseZen, epochSeconds, splitResponse } from '../Sources/TokenHUD/mjs/catalog-rate-provider.mjs';
import { normalizeUsage } from '../Sources/TokenHUD/mjs/usage-normalize.mjs';
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const temp = mkdtempSync(join(tmpdir(), 'tokenhud-catalog-rates-'));
const hud = join(temp, 'hud'); mkdirSync(hud);
copyFileSync(join(repo, 'Sources/TokenHUD/mjs/catalog-rate-provider.mjs'), join(hud, 'catalog-rate-provider.mjs'));
const authFile = join(temp, 'snapshot.json');
const originalFile = join(temp, 'original-auth.json');
const cacheFile = join(temp, 'cache.json');
const argsFile = join(temp, 'args.json');
const curl = join(temp, 'fake-curl');
writeFileSync(curl, `#!${process.execPath}\nimport {writeFileSync} from 'node:fs';\nwriteFileSync(process.env.FIXTURE_ARGS,JSON.stringify(process.argv.slice(2)));\nprocess.stdout.write(process.env.FIXTURE_HEADERS+process.env.FIXTURE_BODY+'\\n'+process.env.FIXTURE_STATUS);\nprocess.exit(Number(process.env.FIXTURE_EXIT||0));\n`, {mode:0o700});
const original = JSON.stringify({ apiKey:'keyB', cookieAuth:'cookieB', cookieToken:'cookieB', scheduleTimes:['08:00'] });
writeFileSync(originalFile, original);
const snapshot = { queryKey:'keyA', apiKey:'keyB', refreshApiKey:'keyB', cookieAuth:'cookieB', cookieToken:'cookieB', headers:{Authorization:'Bearer keyB'}, authFile:originalFile, queryUrl:'https://wrong.invalid' };
const zen = { usage:{ rolling:{percent:'12.5',resetsAt:'2030-01-01T00:00:00Z'}, weekly:{percent:0,resetsAt:1893456000}, monthly:{percent:45,resetsAt:1893456000000} } };
let count = 0;
const args = () => JSON.parse(readFileSync(argsFile, 'utf8'));
function run({body = zen, headers = 'HTTP/2 200\r\nContent-Type: application/json\r\n\r\n', status = 200, auth = snapshot, exit = 0, stdout = true} = {}) {
 const authText=JSON.stringify(auth);
 writeFileSync(authFile,authText);
 const cache=JSON.stringify({generatedAt:123,windows:[{label:'旧数据',used_percentage:50}]});
 writeFileSync(cacheFile,cache);
 const wrapper=join(temp,'fetch.sh');
 writeFileSync(wrapper,readFileSync(join(repo,'Sources/TokenHUD/providers/opencode-zen/fetch.sh'),'utf8').replaceAll('{SLUG}','fixture-account'));
 const result=spawnSync('/bin/zsh',[wrapper],{encoding:'utf8',timeout:5000,env:{PATH:process.env.PATH,HOME:temp,TOKENHUD_HUD_DIR:hud,TOKENHUD_AUTH_FILE:authFile,TOKENHUD_CACHE_FILE:cacheFile,TOKENHUD_NODE:process.execPath,TOKENHUD_CURL:curl,TOKENHUD_STDOUT_ONLY:stdout?'1':'0',TOKENHUD_QUERY_URL:'https://wrong.invalid/env',FIXTURE_HEADERS:headers,FIXTURE_BODY:typeof body==='string'?body:JSON.stringify(body),FIXTURE_STATUS:String(status),FIXTURE_EXIT:String(exit),FIXTURE_ARGS:argsFile}});
 assert.equal(result.status,0,result.stderr);
 assert.equal(readFileSync(authFile,'utf8'),authText,'snapshot unchanged');
 assert.equal(readFileSync(originalFile,'utf8'),original,'persistent original Auth unchanged');
 if(stdout) assert.equal(readFileSync(cacheFile,'utf8'),cache,'stdout-only cache unchanged');
 const output=JSON.parse(result.stdout);
 if(!stdout) assert.deepEqual(JSON.parse(readFileSync(cacheFile,'utf8')),output);
 count++;
 return output;
}
try {
 assert.deepEqual(Object.keys(rateProviders),['opencode-zen']);
 // Locate the exact original URL without executing 9router; portable runs may omit this checkout.
 const source=process.env.TOKENHUD_9ROUTER_SOURCE || '/Users/biedongbin/workspace/github/9router';
 const registry=join(source,'open-sse/providers/registry/opencode-zen.js');
 if(existsSync(registry)) {
  const literal=/usage:\s*\{\s*url:\s*"([^"]+)"/.exec(readFileSync(registry,'utf8'))?.[1];
  assert(literal && !/[{}\s]/.test(literal));
  assert.equal(rateProviders['opencode-zen'].url,literal,'exact source literal');
 }
 const manifest=JSON.parse(readFileSync(join(repo,'Sources/TokenHUD/providers/opencode-zen/manifest.json'),'utf8'));
 assert.equal(manifest.autoCreateDefault,false);
 assert.equal(manifest.authMode,'apikey');
 assert.deepEqual(manifest.quotaAuthModes,['apikey']);
 assert.equal(manifest.queryAuth,'bearer'); assert.equal(manifest.quotaMode,'script');
 assert.equal(manifest.inheritQueryUrl,rateProviders['opencode-zen'].url);
 assert.equal(manifest.testModel,''); assert.equal(manifest.requiresSession,true);
 assert(manifest.refreshHeader.includes('x-opencode-session: tokenhud-<session>'));
 assert(manifest.refreshHeader.includes('x-opencode-session-id: tokenhud-<session>'));
 assert(manifest.refreshHeader.includes('User-Agent: TokenHUD/1.0'));
 assert.equal(manifest.refreshUrl,'https://opencode.ai/zen/v1/chat/completions');
 const output=run();
 assert.equal(output.error,null); assert.equal(output.stale,false);
 assert.equal(normalizeUsage(output).windows.length,3);
 const request=args();
 assert.equal(request[0],'-q'); assert.equal(request.at(-1),rateProviders['opencode-zen'].url);
 assert(request.includes('Authorization: Bearer keyA'));
 assert(!JSON.stringify(request).includes('keyB') && !JSON.stringify(request).includes('cookieB'));
 assert(!request.includes('-L') && !request.includes('--location'));
 assert(request.includes('--max-time') && request.includes('--connect-timeout'));
 assert.equal(request[request.indexOf('--proto')+1],'=https');
 assert(request.includes('-D')); assert(!request.includes('-d') && !request.includes('--data'));
 assert.deepEqual(output.windows.map(w=>w.used_percentage),[12.5,0,45]);
 assert(output.windows.every(w=>w.resets_at===1893456000));
 assert.equal(output.windows[0].period,'rolling');
 assert(output.windows.every(w=>!('amount' in w) && !('limit' in w)));
 for(const body of [{},{usage:{}},{usage:{rolling:{percent:null}}}]) {
  const missing=run({body});
  assert.equal(missing.error,'no-query'); assert.equal(missing.windows,undefined); assert.match(missing.message,/未知/);
 }
 for(const [status,error] of [[401,'auth'],[403,'auth'],[302,'auth'],[429,'ratelimit'],[500,'network']]) assert.equal(run({status}).error,error);
 assert.equal(run({exit:28}).error,'network');
 const marker=readFileSync(argsFile,'utf8');
 assert.equal(run({auth:{...snapshot,queryKey:''}}).error,'no-auth');
 assert.equal(readFileSync(argsFile,'utf8'),marker);
 assert.equal(run({auth:{...snapshot,queryKey:'keyA\r\nBad:value'}}).error,'no-auth');
 assert.equal(readFileSync(argsFile,'utf8'),marker);
 assert.equal(run({body:'not-json'}).error,'parse');
 assert.equal(run({body:{error:{type:'EntitlementError'}},status:403}).error,'no-query');
 const zero=run({body:{usage:{rolling:{percent:0}}}});
 assert.equal(zero.windows[0].used_percentage,0); assert.equal(zero.windows[0].resets_at,null);
 for(const value of [null,'',true,'Infinity',-1]) assert.equal(run({body:{usage:{rolling:{percent:value}}}}).error,'no-query');
 assert.equal(parseZen({usage:{rolling:{percent:20,resetsAt:'invalid'}}}).windows[0].resets_at,null);
 assert.equal(epochSeconds('1893456000000'),1893456000);
 assert.equal(epochSeconds('1893456000'),1893456000); assert.equal(epochSeconds(false),null);
 const intermediate='HTTP/1.1 100 Continue\r\nx-old: old\r\n\r\nHTTP/2 200\r\nx-new: final\r\n\r\n';
 assert.equal(splitResponse(intermediate+'{}').headers['x-old'],undefined);
 assert.equal(run({headers:intermediate}).windows.length,3);
 assert.equal(run({stdout:false}).windows.length,3);
 assert(!existsSync(join(temp,'.claude')));
 console.log(`PASS ${count} offline OpenCode Zen wrapper scenarios plus source/session/reset contracts; no real network or credentials`);
} finally {
 assert.equal(dirname(temp),tmpdir());
 assert(basename(temp).startsWith('tokenhud-catalog-rates-'));
 rmSync(temp,{recursive:true,force:true});
}
