#!/usr/bin/env node
// Offline tests: execute actual wrappers with fake curl and selected snapshot A.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, copyFileSync, rmSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { createHash, createHmac } from 'node:crypto';
import { enterpriseProviders, parseEnterpriseUsage, enterpriseOrigin } from '../Sources/TokenHUD/mjs/catalog-enterprise-provider.mjs';
const root = dirname(dirname(fileURLToPath(import.meta.url))), homes = [];
const accountA = 'a'.repeat(32), accountB = 'b'.repeat(32);
const activeExpiry = new Date(Date.now() + 30 * 86_400_000).toISOString();
const fixtures = {
 codearts: { code: 0, data: { end_date: '2026-12-01T00:00:00Z', metrics: [{ name: 'usageTotalPackageCredit', package_credit_amount: 100, package_credit_remain: 100 }, { name: 'usageBonusPackageCredit', package_credit_amount: 0, package_credit_remain: 0 }] } },
 officeace: { skus: [{ sku_name: '试用', sku_code: 'oa.trial', quotas: [{ sku_attr_code: 'officeace_points', sku_value: 100, current_value: 0, expired_time: '2026-12-01T00:00:00Z' }] }], bonus_skus: [{ activity_name: '奖励', points: 50, current_value: 1, expired_time: activeExpiry }] },
 qwenwork: { data: { user: { is_biz: false }, quota: { total: 100, used: 0, remaining: 100 }, plan: { next_refresh_date: '2026-12-01T00:00:00Z' } } },
 'qwenwork-enterprise': { data: { user: { is_biz: true }, quota: { total: 100, used: 0, remaining: 100 } } },
 orcaterm: { data: { Response: { usageStats: [{ feature: 'hunyuan_ai', quotaUsed: 0, quotaLimit: 100, quotaEndDate: '2026-12-01T00:00:00Z' }, { feature: 'session_share', quotaUsed: 50, quotaLimit: 100 }] } } },
 'cloudflare-workers-ai': { data: { viewer: { accounts: [{ aiInferenceAdaptiveGroups: [{ sum: { totalNeurons: 0 } }] }] } } },
};
function setup(provider) {
 const home = mkdtempSync(join(tmpdir(), 'hud-enterprise-fixture-')); homes.push(home);
 const hud = join(home, '.claude/hud'); mkdirSync(hud, { recursive: true });
 copyFileSync(join(root, 'Sources/TokenHUD/mjs/catalog-enterprise-provider.mjs'), join(hud, 'catalog-enterprise-provider.mjs'));
 const global = join(home, 'original-auth.json');
 writeFileSync(global, JSON.stringify({ access: 'GLOBAL_B', deviceToken: 'GLOBAL_B', access_key_id: 'GLOBAL_B', secret_access_key: 'SECRET_B', security_token: 'SESSION_B', enterpriseHost: 'company-b.vpc.qwenwork.cn', accountId: accountB }));
 const snapshot = join(home, 'snapshot.json');
 const context = provider === 'qwenwork-enterprise' ? { enterpriseHost: 'company-a.vpc.qwenwork.cn' } : provider === 'cloudflare-workers-ai' ? { accountId: accountA } : ['codearts', 'officeace'].includes(provider) ? { secretAccessKey: 'SECRET_A', securityToken: 'SESSION_A', ...(provider === 'officeace' ? { projectId: 'PROJECT_A' } : {}) } : {};
 writeFileSync(snapshot, JSON.stringify({ authMode: 'auth', queryKey: 'SNAPSHOT_A', tokenhudAuthContext: context, authCredentialFile: global }));
 const curl = join(home, 'curl');
 writeFileSync(curl, `#!${process.execPath}\nimport fs from 'node:fs';\nconst args=process.argv.slice(2); fs.appendFileSync(process.env.CURL_LOG,JSON.stringify(args)+'\\n');\nconst url=args[args.indexOf('--url')+1];\nconst code=process.env.HTTP_CODE || '200'; if(code==='EXIT7')process.exit(7);\nconst body=url.endsWith('/accounts')?process.env.DISCOVERY:url.endsWith('/wallets')?process.env.WALLETS:url.includes('opengw.developer.huaweicloud.com')?process.env.BENEFIT:process.env.RESPONSE;\nprocess.stdout.write(body+'\\n'+code);\n`, { mode: 0o755 });
 return { provider, home, hud, global, snapshot, curl };
}
function run(s, body = fixtures[s.provider], extra = {}) {
 const before = readFileSync(s.snapshot, 'utf8'), original = readFileSync(s.global, 'utf8');
 const result = spawnSync('/bin/zsh', [join(root, 'Sources/TokenHUD/providers', s.provider, 'fetch.sh')], { env: { ...process.env, HOME: s.home, CLAUDE_CONFIG_DIR: join(s.home, '.claude'), TOKENHUD_NODE: process.execPath, TOKENHUD_AUTH_FILE: s.snapshot, TOKENHUD_HUD_DIR: s.hud, TOKENHUD_CACHE_FILE: join(s.home, 'cache.json'), TOKENHUD_CURL: s.curl, CURL_LOG: join(s.home, 'curl.log'), RESPONSE: JSON.stringify(body), WALLETS: JSON.stringify({ data: { daily_credits: { total_balance: 0 } } }), BENEFIT: '{}', DISCOVERY: JSON.stringify({ success: true, result: [{ id: accountA }], result_info: { total_count: 1 } }), ...extra }, encoding: 'utf8', timeout: 20000 });
 assert.equal(result.status, 0, result.stderr || result.error?.message);
 assert.equal(readFileSync(s.snapshot, 'utf8'), before); assert.equal(readFileSync(s.global, 'utf8'), original);
 return JSON.parse(result.stdout);
}
const calls = s => existsSync(join(s.home, 'curl.log')) ? readFileSync(join(s.home, 'curl.log'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
const arg = (args, name) => args[args.indexOf(name) + 1];
const headers = args => Object.fromEntries(args.flatMap((v, i) => v === '-H' ? [args[i + 1].split(/: (.*)/s).slice(0, 2)] : []));
const replaceSnapshot = (s, patch) => writeFileSync(s.snapshot, JSON.stringify({ ...JSON.parse(readFileSync(s.snapshot, 'utf8')), ...patch }));
after(() => { for (const home of homes) { assert.ok(resolve(home).startsWith(join(tmpdir(), 'hud-enterprise-fixture-'))); rmSync(home, { recursive: true, force: true }); } });
for (const provider of Object.keys(enterpriseProviders)) {
 test(`${provider}: actual wrapper uses exact URL/header/body and snapshot A only`, () => {
  const s = setup(provider), output = run(s), requests = calls(s), args = requests[0], h = headers(args);
  assert.equal(output.error, null); assert.equal(output.stale, false); assert.ok(output.windows.some(w => w.amount === 0));
  assert.ok(!JSON.stringify(output).includes('SNAPSHOT_A')); assert.ok(!JSON.stringify(output).includes('SECRET_A'));
  assert.ok(!JSON.stringify(requests).includes('GLOBAL_B')); assert.ok(!JSON.stringify(requests).includes('SESSION_B')); assert.ok(!JSON.stringify(requests).includes(accountB));
  for (const request of requests) { assert.equal(request[0], '-q'); assert.ok(request.includes('--max-time')); assert.equal(arg(request, '--proto'), '=https'); assert.ok(!request.includes('-L') && !request.includes('--location')); }
  if (provider.startsWith('qwenwork')) {
   const base = provider === 'qwenwork' ? 'https://gateway.qwenwork.cn' : 'https://company-a.vpc.qwenwork.cn';
   assert.equal(arg(args, '--url'), `${base}/api/v1/adapter/user/account-context?include=user,plan,quota`);
   assert.equal(h.Authorization, 'Bearer SNAPSHOT_A'); assert.equal(h['User-Agent'], 'qoderwork/1.2.1'); assert.equal(h['X-QwenWork-Release-Version'], '1.2.1-26092107'); assert.equal(h['X-QwenWork-Build'], '26092107'); assert.equal(h['X-QwenWork-Platform'], 'darwin'); assert.match(h['X-Request-Id'], /^[\da-f-]{36}$/);
   assert.equal(requests.length, provider === 'qwenwork' ? 2 : 1); assert.ok(!args.includes('--data-binary'));
   if (provider === 'qwenwork') assert.equal(arg(requests[1], '--url'), `${base}/api/v1/adapter/user/wallets`);
  } else if (provider === 'orcaterm') {
   const url = new URL(arg(args, '--url')); assert.equal(url.origin + url.pathname, 'https://orcaterm.com/cgi/api'); assert.equal(url.searchParams.get('action'), 'DescribeUserBillingStatus'); assert.equal(url.searchParams.get('t'), h['x-seqid']);
   assert.deepEqual(JSON.parse(arg(args, '--data-binary')), { action: 'DescribeUserBillingStatus', data: {} }); assert.equal(h.Cookie, ['ot', 'session'].join('_') + '=' + 'SNAPSHOT_A'); assert.equal(h.Origin, 'https://orcaterm.com'); assert.equal(h.Referer, 'https://orcaterm.com/terminal'); assert.equal(h.Authorization, undefined);
   assert.equal(output.windows.length, 1);
  } else if (provider === 'cloudflare-workers-ai') {
   assert.equal(arg(args, '--url'), enterpriseProviders[provider].url); assert.equal(h.Authorization, 'Bearer SNAPSHOT_A');
   const body = JSON.parse(arg(args, '--data-binary')); assert.deepEqual(Object.keys(body), ['query']); assert.ok(body.query.includes(`accountTag: "${accountA}"`)); assert.ok(body.query.includes('aiInferenceAdaptiveGroups(limit: 100')); assert.ok(body.query.includes('sum { totalNeurons }')); assert.match(body.query, /datetimeHour_geq: "\d{4}-\d\d-\d\dT00:00:00.000Z"/); assert.ok(output.windows.every(w => w.limit === undefined && w.used_percentage === undefined));
  } else {
   assert.equal(arg(args, '--url'), enterpriseProviders[provider].url); assert.equal(h['x-security-token'], 'SESSION_A'); assert.ok(!args.includes('--data-binary')); assert.ok(!JSON.stringify(args).includes('SECRET_A'));
   verifySignature(provider, h);
  }
 });
 test(`${provider}: missing usage, service and transport errors delegate last-good retention to the native engine`, () => {
  const s = setup(provider), good = run(s);
  assert.equal(run(s, {}, { WALLETS: '{}' }).error, 'parse');
  for (const [code, error] of [['401', 'auth'], ['403', 'auth'], ['429', 'ratelimit'], ['302', 'network'], ['500', 'network'], ['EXIT7', 'network']]) {
   const bad = run(s, { key: 'NO_LEAK' }, { HTTP_CODE: code }); assert.equal(bad.error, error); assert.equal(bad.stale, true); assert.equal(bad.windows, undefined); assert.ok(!JSON.stringify(bad).includes('NO_LEAK'));
  }
 });
 test(`${provider}: never reads global auth; invalid context and unsupported API Key stop before curl`, () => {
  const s = setup(provider); replaceSnapshot(s, { queryKey: '' }); assert.equal(run(s).error, 'no-auth'); assert.equal(calls(s).length, 0);
  assert.equal(run(s, {}, { TOKENHUD_AUTH_FILE: '' }).error, 'no-auth'); assert.equal(calls(s).length, 0);
  replaceSnapshot(s, { queryKey: 'A', tokenhudAuthContext: { injected: 'bad\r\nvalue' } }); assert.equal(run(s).error, 'no-auth'); assert.equal(calls(s).length, 0);
  if (provider !== 'cloudflare-workers-ai') { replaceSnapshot(s, { authMode: 'apikey', queryKey: 'A', tokenhudAuthContext: {} }); assert.equal(run(s).error, 'no-query'); assert.equal(calls(s).length, 0); }
 });
 test(`${provider}: manifest is manual creation, explicit Auth source, quota-only`, () => {
  const m = JSON.parse(readFileSync(join(root, 'Sources/TokenHUD/providers', provider, 'manifest.json'), 'utf8'));
  assert.equal(m.autoCreateDefault, false); assert.equal(m.credentialSource.file, ''); assert.ok(m.credentialSource.tokenPath); assert.equal(m.refreshUrl, undefined); assert.equal(m.authCallUrl, undefined); assert.equal(m.authModelsUrl, undefined); assert.equal(m.testModel, undefined); assert.equal(m.quotaMode, 'script'); assert.deepEqual(m.quotaAuthModes, enterpriseProviders[provider].modes);
 });
}
function verifySignature(provider, h) {
 const sha = s => createHash('sha256').update(s).digest('hex'), mac = (k, s, encoding) => createHmac('sha256', k).update(s).digest(encoding);
 const office = provider === 'officeace';
 const signed = office ? 'host;x-project-id;x-sdk-date;x-security-token;x-subscription-type' : 'host;x-sdk-content-sha256;x-sdk-date;x-security-token';
 const block = office ? `host:officeace.cn-southwest-2.huaweicloud-agentarts.com\nx-project-id:PROJECT_A\nx-sdk-date:${h['x-sdk-date']}\nx-security-token:SESSION_A\nx-subscription-type:v2\n` : `host:${provider === 'benefit' ? 'opengw.developer.huaweicloud.com' : 'snap-access.cn-north-4.myhuaweicloud.com'}\nx-sdk-content-sha256:${sha('')}\nx-sdk-date:${h['x-sdk-date']}\nx-security-token:SESSION_A\n`;
 const path = office ? '/v1/subscription/' : provider === 'benefit' ? '/api/v1/user/tokens/balance/' : '/snap-manager/v1/statistics/plugin/';
 const canonical = `GET\n${path}\n\n${block}\n${signed}\n${sha('')}`;
 if (office) {
  const scope = `${h['x-sdk-date'].slice(0,8)}/cn-southwest-2/apic`;
  const signingKey = mac(mac('SNAPSHOT_A', 'SECRET_A'), Buffer.concat([Buffer.from(scope), Buffer.from([1])]), 'hex');
  assert.equal(h.Authorization, `V11-HMAC-SHA256 Credential=SNAPSHOT_A/${scope}, SignedHeaders=${signed}, Signature=${mac(signingKey, `V11-HMAC-SHA256\n${h['x-sdk-date']}\n${scope}\n${sha(canonical)}`, 'hex')}`);
  assert.equal(h['x-project-id'], 'PROJECT_A'); assert.equal(h['x-subscription-type'], 'v2');
 } else {
  assert.equal(h.Authorization, `SDK-HMAC-SHA256 Access=SNAPSHOT_A,SignedHeaders=${signed},Signature=${mac('SECRET_A', `SDK-HMAC-SHA256\n${h['x-sdk-date']}\n${sha(canonical)}`, 'hex')}`); if (provider === 'codearts') { assert.equal(h['Agent-Type'], 'PromptCenter'); assert.equal(h['X-Language'], 'zh-cn'); } else { assert.equal(h['Agent-Type'], undefined); assert.equal(h['X-Language'], undefined); }
 }
}
test('QwenWork enterprise requires its explicit controlled host; public never probes an enterprise token', () => {
 for (const host of ['', 'gateway.qwenwork.cn', 'http://a.vpc.qwenwork.cn', '127.0.0.1', 'localhost', 'company.internal', 'company.local', 'a.vpc.qwenwork.cn/path', 'a.vpc.qwenwork.cn:8443', 'https://user@enterprise.example.com']) {
  const s = setup('qwenwork-enterprise'); replaceSnapshot(s, { tokenhudAuthContext: host ? { enterpriseHost: host } : {} }); assert.equal(run(s).error, 'no-auth'); assert.equal(calls(s).length, 0);
 }
 for (const host of ['enterprise.example.com', 'https://enterprise.example.com/']) {
  const selected = setup('qwenwork-enterprise'); replaceSnapshot(selected, { tokenhudAuthContext: { enterpriseHost: host } }); assert.equal(run(selected).error, null); assert.equal(calls(selected).length, 1); assert.equal(new URL(arg(calls(selected)[0], '--url')).origin, 'https://enterprise.example.com');
 }
 assert.equal(enterpriseOrigin('https://user:invalid@enterprise.example.com'), null);
 const s = setup('qwenwork'); replaceSnapshot(s, { tokenhudAuthContext: { enterpriseHost: 'a.vpc.qwenwork.cn' } }); assert.equal(run(s).error, 'no-auth'); assert.equal(calls(s).length, 0);
});
test('Cloudflare same-token account discovery, explicit selection, Auth metadata and API Key', () => {
 for (const authMode of ['auth', 'apikey']) {
  const s = setup('cloudflare-workers-ai'); replaceSnapshot(s, { authMode, tokenhudAuthContext: {} }); assert.equal(run(s).error, null);
  const requests = calls(s); assert.equal(requests.length, 2); assert.equal(arg(requests[0], '--url'), 'https://api.cloudflare.com/client/v4/accounts'); assert.equal(headers(requests[0]).Authorization, 'Bearer SNAPSHOT_A'); assert.equal(headers(requests[1]).Authorization, 'Bearer SNAPSHOT_A');
 }
 for (const discovery of [{ success: true, result: [{ id: accountA }, { id: accountB }] }, { success: true, result: [{ id: accountA }], result_info: { total_count: 2 } }, { success: true, result: [] }]) {
  const s = setup('cloudflare-workers-ai'); replaceSnapshot(s, { tokenhudAuthContext: {} }); assert.equal(run(s, fixtures[s.provider], { DISCOVERY: JSON.stringify(discovery) }).error, 'account-selection-required'); assert.equal(calls(s).length, 1);
 }
 const s = setup('cloudflare-workers-ai'); replaceSnapshot(s, { tokenhudAuthContext: { metadataAccountId: accountA } }); assert.equal(run(s).error, null); assert.equal(calls(s).length, 1);
 const conflict = setup('cloudflare-workers-ai'); replaceSnapshot(conflict, { tokenhudAuthContext: { metadataAccountId: accountB, accountId: accountA } }); assert.equal(run(conflict).error, 'account-selection-required'); assert.equal(calls(conflict).length, 0);
});
test('zero versus missing, unknown limits, reset versus bucket expiration', () => {
 assert.equal(parseEnterpriseUsage('codearts', { code: 4, data: fixtures.codearts.data }), null);
 assert.equal(parseEnterpriseUsage('codearts', { metrics: [{ name: 'usageTotalPackageCredit', package_credit_amount: null, package_credit_remain: 0 }] }).windows[0].period, 'balance');
 const office = parseEnterpriseUsage('officeace', fixtures.officeace).windows; assert.ok(office.every(w => w.resets_at === undefined)); assert.ok(!office[0].label.includes('到期')); assert.ok(office[1].label.includes('到期'));
 assert.equal(parseEnterpriseUsage('officeace', { skus: [{ sku_code: 'paid', quotas: [{ sku_attr_code: 'officeace_points', sku_value: 100, current_value: 5, expired_time: '2020-01-01T00:00:00Z' }] }], bonus_skus: [{ points: 100, current_value: 5, expired_time: '2020-01-01T00:00:00Z' }] }), null);
 assert.equal(parseEnterpriseUsage('officeace', { skus: [{ sku_code: 'oa.trial', quotas: [{ sku_attr_code: 'officeace_points', sku_value: 100, current_value: 5, expired_time: '2020-01-01T00:00:00Z' }] }] }).windows.length, 1);
 const qwen = parseEnterpriseUsage('qwenwork', { quota: { total: null, used: null, remaining: 0 } }).windows; assert.deepEqual(qwen, [{ label: '可用积分余额', amount: 0, unit: 'credits', period: 'balance' }]);
 assert.equal(parseEnterpriseUsage('qwenwork', { quota: { total: 100, used: null, remaining: null } }), null);
 for (const provider of ['officeace', 'orcaterm']) {
  const raw = provider === 'officeace' ? { skus: [{ quotas: [{ sku_attr_code: 'officeace_points', current_value: 0 }] }] } : { Response: { usageStats: [{ feature: 'hunyuan_ai', quotaUsed: 0 }] } };
  const w = parseEnterpriseUsage(provider, raw).windows[0]; assert.equal(w.amount, 0); assert.equal(w.limit, undefined); assert.equal(w.used_percentage, undefined);
 }
 const cf = rows => ({ data: { viewer: { accounts: [{ aiInferenceAdaptiveGroups: rows }] } } });
 assert.equal(parseEnterpriseUsage('cloudflare-workers-ai', cf([]), 1794000000).windows[0].amount, 0);
 assert.equal(parseEnterpriseUsage('cloudflare-workers-ai', cf([{ sum: {} }]), 1794000000), null);
 assert.equal(parseEnterpriseUsage('cloudflare-workers-ai', { ...cf([]), errors: [{ message: 'scope' }] }, 1794000000), null);
 assert.equal(parseEnterpriseUsage('cloudflare-workers-ai', cf([{ sum: { totalNeurons: 20 } }, { sum: { totalNeurons: 30 } }]), 1794000000).windows[0].amount, 50);
});
test('CodeArts free-only quota uses same STS snapshot, real tokens and Beijing daily reset', () => {
 const s = setup('codearts');
 const output = run(s, { code: 0, data: { metrics: [] } }, { BENEFIT: JSON.stringify({ result: { daily_token_limit: 2000, daily_tokens_used: 0 } }) });
 assert.equal(output.error, null); assert.equal(output.windows.length, 1); const w = output.windows[0]; assert.equal(w.amount, 0); assert.equal(w.limit, 2000); assert.equal(w.unit, 'tokens'); assert.equal(w.used_percentage, 0); assert.equal(new Date(w.resets_at * 1000).getUTCHours(), 16);
 const requests = calls(s); assert.equal(requests.length, 2); assert.equal(arg(requests[1], '--url'), 'https://opengw.developer.huaweicloud.com/api/v1/user/tokens/balance'); assert.equal(headers(requests[1])['x-security-token'], 'SESSION_A'); verifySignature('benefit', headers(requests[1]));
 assert.equal(parseEnterpriseUsage('codearts', { metrics: [] }, { result: { daily_token_limit: 2000 } }), null);
});
test('Huawei missing paired credential never requests quota; OrcaTerm refuses raw cookies', () => {
 for (const provider of ['codearts', 'officeace']) {
  const s = setup(provider); replaceSnapshot(s, { tokenhudAuthContext: { securityToken: 'SESSION_A' } }); assert.equal(run(s).error, 'no-auth'); assert.equal(calls(s).length, 0);
 }
 const s = setup('orcaterm'); replaceSnapshot(s, { queryKey: 'uin=123; skey=secret' }); assert.equal(run(s).error, 'no-auth'); assert.equal(calls(s).length, 0);
});
