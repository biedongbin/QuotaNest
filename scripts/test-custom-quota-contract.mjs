#!/usr/bin/env node
// Custom quota: Native-resolved snapshots only; fake curl, no real credentials/network.
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
const repo=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const temp=mkdtempSync(join(tmpdir(),'tokenhud-custom-quota-'));
const authFile=join(temp,'snapshot.json'),originalFile=join(temp,'original.json'),cacheFile=join(temp,'cache.json'),argsFile=join(temp,'args.json'),curl=join(temp,'curl');
const original=JSON.stringify({queryKey:'keyB',apiKey:'keyB',cookieToken:'cookieB',cookieAuth:'cookieB'});
writeFileSync(originalFile,original);
writeFileSync(curl,`#!${process.execPath}\nimport {writeFileSync} from 'node:fs';\nwriteFileSync(process.env.ARGS,JSON.stringify(process.argv.slice(2)));\nprocess.stdout.write(process.env.BODY+'\\n'+process.env.STATUS);\nprocess.exit(Number(process.env.EXIT||0));\n`,{mode:0o700});
const snapshot={tokenhudResolvedAuth:true,authMode:'apikey',quotaMode:'endpoint',queryUrl:'https://quota.invalid/complete/path?account=one',queryKey:'keyA',refreshApiKey:'keyB',cookieAuth:'cookieB',cookieToken:'cookieB',authFile:originalFile};
const body={windows:[{label:'余额',amount:0,unit:'USD',period:'balance'},{label:'自定义窗口',used_percentage:12,resets_at:1893456000}]};
let count=0;
const args=()=>JSON.parse(readFileSync(argsFile,'utf8'));
function run(auth,{payload=body,status=200,exit=0}={}) {
 const text=JSON.stringify(auth);writeFileSync(authFile,text);writeFileSync(cacheFile,'unchanged-cache');
 const result=spawnSync(process.execPath,[join(repo,'Sources/TokenHUD/mjs/generic-usage-provider.mjs')],{encoding:'utf8',timeout:5000,env:{PATH:process.env.PATH,HOME:temp,TOKENHUD_AUTH_FILE:authFile,TOKENHUD_CACHE_FILE:cacheFile,TOKENHUD_CURL:curl,TOKENHUD_STDOUT_ONLY:'1',ARGS:argsFile,BODY:typeof payload==='string'?payload:JSON.stringify(payload),STATUS:String(status),EXIT:String(exit)}});
 assert.equal(result.status,0,result.stderr);assert.equal(result.stderr,'','no credentials logged');
 assert.equal(readFileSync(authFile,'utf8'),text);assert.equal(readFileSync(originalFile,'utf8'),original);assert.equal(readFileSync(cacheFile,'utf8'),'unchanged-cache');
 count++;return JSON.parse(result.stdout);
}
try {
 // This assertion reproduces the previous fixed-Bearer bug before implementation changes.
 const anthropic={...snapshot,headers:{'x-api-key':'keyA','anthropic-version':'2023-06-01'}};
 let output=run(anthropic);assert.equal(output.error,null);
 assert(args().includes('x-api-key: keyA'),'Anthropic quota must inherit the Native x-api-key header');
 assert(args().includes('anthropic-version: 2023-06-01'));
 assert(!args().some(value=>/^Authorization:/i.test(value)),'Anthropic must not get invented Bearer');
 for(const auth of [anthropic,{...snapshot,headers:{Authorization:'Bearer keyA'}},{...snapshot},{...snapshot,headers:{}}]) {
  output=run(auth);assert.equal(output.windows[0].amount,0);assert.equal(output.windows[1].used_percentage,12);
  const request=args();assert.equal(request[0],'-q');assert.equal(request.at(-1),snapshot.queryUrl);
  assert(!JSON.stringify(request).includes('keyB')&&!JSON.stringify(request).includes('cookieB'));
  assert(request.includes('--max-time')&&request.includes('--connect-timeout'));
  assert.equal(request[request.indexOf('--proto')+1],'=https,http');
  assert(!request.includes('-L')&&!request.includes('--location'));assert(!request.includes('-d'));
 }
 assert(args().includes('Authorization: Bearer keyA'),'no headers retains base-key Bearer compatibility');
 const marker=readFileSync(argsFile,'utf8');
 const rejected=[JSON.parse(original),{...snapshot,tokenhudResolvedAuth:false},
  {...snapshot,headers:[]},{...snapshot,headers:'Authorization: Bearer keyB'},
  {...snapshot,headers:{'bad\nname':'keyA'}},{...snapshot,headers:{'x-api-key':'keyA\r\nCookie: cookieB'}},
  {...snapshot,headers:{'x-api-key':'keyA\0'}},{...snapshot,headers:{'x-api-key':'keyA\t'}},
  {...snapshot,headers:{'x-api-key':false}},{...snapshot,headers:null},
  {...snapshot,queryKey:''},{...snapshot,queryKey:'keyA\0'}];
 for(const auth of rejected) {assert.equal(run(auth).error,'no-auth');assert.equal(readFileSync(argsFile,'utf8'),marker,'invalid inputs must not invoke curl');}
 for(const url of ['file:///tmp/secret','ftp://quota.invalid/x','https://user:pass@quota.invalid/x']) {
  assert.equal(run({...snapshot,queryUrl:url}).error,'no-query');assert.equal(readFileSync(argsFile,'utf8'),marker);
 }
 output=run({...snapshot,queryUrl:'http://localhost:8765/exact?x=1',headers:{Authorization:'Bearer keyA'}});
 assert.equal(output.error,null);assert.equal(args().at(-1),'http://localhost:8765/exact?x=1');
 for(const [status,error] of [[401,'auth'],[403,'auth'],[429,'ratelimit'],[302,'network'],[500,'network']]) assert.equal(run(anthropic,{status}).error,error);
 assert.equal(run(anthropic,{exit:28}).error,'network');assert.equal(run(anthropic,{payload:'invalid JSON'}).error,'parse');
 assert.equal(run(anthropic,{payload:{windows:[{amount:null}]}}).error,'parse');
 assert.equal(run({...snapshot,quotaMode:'none'}).error,'no-query');
 assert(!existsSync(join(temp,'.claude')));
 console.log(`PASS ${count} offline custom quota snapshot/header/URL/credential contracts`);
} finally {assert.equal(dirname(temp),tmpdir());assert(basename(temp).startsWith('tokenhud-custom-quota-'));rmSync(temp,{recursive:true,force:true});}
