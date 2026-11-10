// Offline end-to-end regression: exported HUD v2 entry -> copied runner + copied
// provider wrapper -> real gpt/glm/cline adapters -> fake curl. No network, no
// QuotaNest process/config, no real credential. A (Magpie) is synthetic and read-only.
// Run: node --test scripts/test-hud-provider-integration.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync,
  chmodSync, copyFileSync, rmSync, statSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { accountIdentity } from '../Sources/TokenHUD/mjs/source-readers.mjs';

const REPO = fileURLToPath(new URL('..', import.meta.url));
const MJS = join(REPO, 'Sources/TokenHUD/mjs');
const PROVIDERS = join(REPO, 'Sources/TokenHUD/providers');

const sha256 = (buffer) => createHash('sha256').update(buffer).digest('hex');
const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'));

// Synthetic credentials that must never reach C's cache or terminal output.
const GPT_TOKEN = 'synthetic-gpt-access-token-1';
const GPT_ACCOUNT = 'acct-gpt-synthetic';
const GLM_KEY = 'synthetic-glm-refresh-key-1';
const CLINE_KEY = 'synthetic-cline-key-1';

function fileHashes(directory) {
  const out = {};
  for (const name of readdirSync(directory).sort()) {
    const path = join(directory, name);
    out[name] = sha256(readFileSync(path));
  }
  return out;
}

// Mirrors HUDSync.entry for an imported (reference) account of a built-in template.
function exportedEntry(slug, manifest, reference, hud) {
  const source = manifest.credentialSource;
  const formats = source ? [primaryFormat(source), ...(source.alternatives || [])] : null;
  const override = manifest.inheritQueryHeader;
  const apiHeader = override ?? manifest.refreshHeader ?? 'Authorization: Bearer <key>';
  const authHeader = override ?? manifest.authCallHeader ?? 'Authorization: Bearer <key>';
  return {
    schemaVersion: 2,
    label: manifest.displayName || manifest.label || slug,
    source: 'cache',
    cache: join(hud, `.${slug}-hud-cache.json`),
    buckets: manifest.buckets,
    fetch: join(hud, 'providers', slug, 'fetch.sh'),
    query: {
      url: manifest.inheritQueryUrl ?? manifest.queryUrl ?? '',
      headerTemplate: apiHeader,
      authHeaderTemplate: authHeader,
      inheritHeaders: override == null,
      ...(manifest.queryKeyField ? { keyField: manifest.queryKeyField } : {}),
      ...(manifest.quotaAuthModes ? { quotaAuthModes: manifest.quotaAuthModes } : {}),
      ...(manifest.queryAuth ? { queryAuth: manifest.queryAuth } : {}),
    },
    reference,
    ...(formats ? { credential: { formats } } : {}),
    managedBy: 'quotanest',
  };
}

function primaryFormat(source) {
  return {
    tokenPath: source.tokenPath,
    ...(source.headerPaths ? { headerPaths: source.headerPaths } : {}),
    ...(source.requiredValues ? { requiredValues: source.requiredValues } : {}),
    ...(source.contextPaths ? { contextPaths: source.contextPaths } : {}),
    ...(source.tokenEncoding ? { tokenEncoding: source.tokenEncoding } : {}),
  };
}

function writeFakeCurl(root) {
  const bin = join(root, 'bin');
  mkdirSync(bin, { recursive: true });
  const shim = join(bin, 'curl');
  const source = String.raw`#!${process.execPath}
const fs = require('fs');
const path = require('path');
const argv = process.argv.slice(2);
const headers = {};
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '-H' && argv[i + 1]) {
    const split = argv[i + 1].indexOf(':');
    if (split > 0) headers[argv[i + 1].slice(0, split).trim().toLowerCase()] = argv[i + 1].slice(split + 1).trim();
    i++;
  }
}
const url = argv.find(arg => /^https?:\/\//.test(arg));
const name = /chatgpt\.com/.test(url) ? 'gpt'
  : /bigmodel\.cn/.test(url) ? 'glm'
  : /api\.cline\.bot/.test(url) ? 'cline' : null;
if (!name) { process.stderr.write('unexpected fake-curl url\n'); process.exit(9); }
fs.appendFileSync(process.env.FAKE_CURL_LOG, JSON.stringify({ url, headers }) + '\n');
process.stdout.write(fs.readFileSync(path.join(process.env.FAKE_CURL_FIXTURES, name + '.json'), 'utf8'));
if (argv.includes('-w')) process.stdout.write('\n200');
`;
  writeFileSync(shim, source);
  chmodSync(shim, 0o755);
  return shim;
}

function createHarness(t, slug, referenceFor) {
  const root = mkdtempSync(join(tmpdir(), 'hud-provider-integ-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const a = join(root, 'A');
  const hud = join(root, 'hud');
  const fixtures = join(root, 'curl');
  mkdirSync(a, { recursive: true });
  mkdirSync(hud, { recursive: true });
  mkdirSync(fixtures, { recursive: true });

  // Synthetic A: Magpie logins + plugin-auth/provider mapping + providers (keys).
  const loginsPath = join(a, 'logins.json');
  const authPath = join(a, 'plugin-auth.json');
  const providersPath = join(a, 'providers.json');
  const pluginProvidersPath = join(a, 'plugin-providers.json');
  const codexAuth = {
    auth_mode: 'chatgpt',
    tokens: { access_token: GPT_TOKEN, account_id: GPT_ACCOUNT },
  };
  writeFileSync(loginsPath, JSON.stringify([
    { id: 'login-gpt', agent: 'codex', seen: '2026-11-09T10:00:00Z', auth: codexAuth },
  ]));
  writeFileSync(authPath, JSON.stringify({
    // Magpie stores this payload as an embedded JSON string in real ZCode logins.
    'zcode#acct-glm': { type: 'oauth', refresh: JSON.stringify({ key: GLM_KEY, site: 'bigmodel' }) },
  }));
  writeFileSync(providersPath, JSON.stringify({
    providers: [
      { id: 'zcode', name: 'ZCode' },
      { id: 'clinepass', key: CLINE_KEY, keyProtocol: 'openai', chat: 'https://api.cline.bot' },
    ],
  }));
  writeFileSync(pluginProvidersPath, JSON.stringify([
    { id: 'zcode', accounts: [{ key: 'zcode#acct-glm', type: 'oauth' }] },
  ]));
  const aBefore = fileHashes(a);

  // C side: copy the real runner, runtime, readers and adapters plus the real wrappers.
  for (const file of ['ref-usage-provider.mjs', 'hud-runtime.mjs', 'source-readers.mjs',
    'gpt-usage-provider.mjs', 'glm-usage-provider.mjs', 'cline-usage-provider.mjs']) {
    copyFileSync(join(MJS, file), join(hud, file));
  }
  const manifest = readJson(join(PROVIDERS, slug, 'manifest.json'));
  const wrapper = readFileSync(join(PROVIDERS, slug, 'fetch.sh'), 'utf8').replaceAll('{SLUG}', slug);
  const wrapperPath = join(hud, 'providers', slug, 'fetch.sh');
  mkdirSync(dirname(wrapperPath), { recursive: true });
  writeFileSync(wrapperPath, wrapper, { mode: 0o755 });
  chmodSync(wrapperPath, 0o755);

  const reference = referenceFor({ loginsPath, authPath, providersPath, codexAuth });
  const entry = exportedEntry(slug, manifest, reference, hud);
  assert.equal(entry.schemaVersion, 2);
  assert.equal(entry.cache, join(hud, `.${slug}-hud-cache.json`));
  assert.equal(entry.fetch, wrapperPath);
  writeFileSync(join(hud, 'envs.json'), JSON.stringify({ [slug]: entry }, null, 2));

  const curl = writeFakeCurl(root);
  const log = join(root, 'curl.log');
  const run = () => spawnSync(process.execPath, [join(hud, 'ref-usage-provider.mjs'), slug], {
    cwd: root,
    encoding: 'utf8',
    timeout: 30_000,
    env: {
      ...process.env,
      HOME: root,
      CLAUDE_CONFIG_DIR: join(root, 'claude-config'),
      TOKENHUD_HUD_DIR: hud,
      TOKENHUD_CURL: curl,
      CODEX_HOME: join(root, 'no-codex-home'),
      FAKE_CURL_LOG: log,
      FAKE_CURL_FIXTURES: fixtures,
    },
  });
  const requests = () => {
    if (!existsSync(log)) return [];
    return readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  };
  const cachePath = join(hud, `.${slug}-hud-cache.json`);
  return {
    root, hud, a, aBefore, run, requests, cachePath, entry, wrapperPath, wrapper,
    codexAuth, loginsPath, authPath, providersPath,
  };
}

const gptReference = ({ loginsPath, codexAuth }) => ({
  source: 'magpie', path: loginsPath, recordId: 'login-gpt', providerId: 'codex', collection: 'logins',
  identityAccount: accountIdentity(codexAuth),
});

const glmReference = ({ authPath }) => ({
  source: 'magpie', path: authPath, recordId: 'zcode#acct-glm', providerId: 'zcode',
  collection: 'plugin-auth', credentialProviderId: 'zcode',
});

const clineReference = ({ providersPath }) => ({
  source: 'magpie', path: providersPath, recordId: 'clinepass', providerId: 'clinepass',
  collection: 'providers',
});

function assertCOnly(harness, slug, result) {
  const names = readdirSync(harness.hud).sort();
  assert.ok(names.includes(`.${slug}-hud-cache.json`));
  assert.ok(names.includes('envs.json'));
  assert.ok(!names.includes('settings.json'), 'must not write Claude/B settings');
  assert.ok(!names.some(name => name.endsWith('-usage-cache.json')), 'must not write B caches');
  assert.ok(!readdirSync(`${harness.cachePath}.lock`).some(name => name.endsWith('.claim')), 'worker claim must be released');
  assert.ok(!names.some(name => name.endsWith('.tmp')), 'no temporary publish files may remain');
  assert.equal(result.status, 0);
  assert.equal(result.stderr, '');
  assert.ok(!result.stdout.includes('QuotaNest'));
}

test('gpt adapter: login logins -> header auth, account header, quota in C cache only', (t) => {
  const harness = createHarness(t, 'gpt', gptReference);
  writeFileSync(join(harness.root, 'curl', 'gpt.json'), JSON.stringify({
    rate_limit: {
      primary_window: { used_percent: 11, limit_window_seconds: 18000, reset_at: 1800000000 },
      secondary_window: { used_percent: 33, limit_window_seconds: 604800, reset_at: 1800600000 },
    },
  }));

  const result = harness.run();
  assertCOnly(harness, 'gpt', result);
  const cache = readJson(harness.cachePath);
  assert.equal(cache.error, null);
  assert.equal(cache.stale, false);
  assert.equal(cache.five_hour.used_percentage, 11);
  assert.equal(cache.seven_day.used_percentage, 33);
  assert.match(cache.configuration, /^[0-9a-f]{64}$/);
  assert.match(cache.binding, /^[0-9a-f]{64}$/);

  const requests = harness.requests();
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, 'https://chatgpt.com/backend-api/wham/usage');
  assert.equal(requests[0].headers.authorization, `Bearer ${GPT_TOKEN}`);
  assert.equal(requests[0].headers['chatgpt-account-id'], GPT_ACCOUNT);

  const output = result.stdout + result.stderr;
  assert.ok(!output.includes(GPT_TOKEN));
  assert.ok(!readFileSync(harness.cachePath, 'utf8').includes(GPT_TOKEN));
  assert.deepEqual(fileHashes(harness.a), harness.aBefore, 'A must not be modified');
});

test('glm adapter: plugin-auth record -> apikey header, template URL, quota in C cache only', (t) => {
  const harness = createHarness(t, 'glm', glmReference);
  writeFileSync(join(harness.root, 'curl', 'glm.json'), JSON.stringify({
    code: 200,
    success: true,
    data: {
      limits: [
        { type: 'TOKENS_LIMIT', unit: 3, number: 5, percentage: 21, nextResetTime: 1800000000000 },
        { type: 'TOKENS_LIMIT', unit: 6, number: 0, percentage: 45, nextResetTime: 1800600000000 },
      ],
    },
  }));

  const result = harness.run();
  assertCOnly(harness, 'glm', result);
  const cache = readJson(harness.cachePath);
  assert.equal(cache.error, null);
  assert.equal(cache.five_hour.used_percentage, 21);
  assert.equal(cache.seven_day.used_percentage, 45);

  const requests = harness.requests();
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, 'https://open.bigmodel.cn/api/monitor/usage/quota/limit');
  assert.equal(requests[0].headers.authorization, GLM_KEY);
  // inheritHeaders=false: no credential header paths may be added on top of the template.
  assert.deepEqual(Object.keys(requests[0].headers).sort(), ['authorization']);

  const output = result.stdout + result.stderr;
  assert.ok(!output.includes(GLM_KEY));
  assert.ok(!readFileSync(harness.cachePath, 'utf8').includes(GLM_KEY));
  assert.deepEqual(fileHashes(harness.a), harness.aBefore, 'A must not be modified');
});

test('cline adapter: provider key -> bearer header, monthly cap, C cache only', (t) => {
  const harness = createHarness(t, 'cline', clineReference);
  writeFileSync(join(harness.root, 'curl', 'cline.json'), JSON.stringify({
    data: {
      limits: [
        { type: 'five_hour', percentUsed: 12.5, resetsAt: '2026-11-10T00:00:00Z' },
        { type: 'weekly', percentUsed: 34, resetsAt: '2026-11-16T00:00:00Z' },
        { type: 'monthly', percentUsed: 56, resetsAt: '2026-12-01T00:00:00Z' },
      ],
    },
  }));

  const result = harness.run();
  assertCOnly(harness, 'cline', result);
  const cache = readJson(harness.cachePath);
  assert.equal(cache.error, null);
  assert.equal(cache.five_hour.used_percentage, 12.5);
  assert.equal(cache.seven_day.used_percentage, 34);
  assert.equal(cache.monthly.used_percentage, 56);

  const requests = harness.requests();
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, 'https://api.cline.bot/api/v1/users/me/plan/usage-limits');
  assert.equal(requests[0].headers.authorization, `Bearer ${CLINE_KEY}`);
  assert.equal(requests[0].headers['x-client-type'], 'cline-desktop');

  const output = result.stdout + result.stderr;
  assert.ok(!output.includes(CLINE_KEY));
  assert.ok(!readFileSync(harness.cachePath, 'utf8').includes(CLINE_KEY));
  assert.deepEqual(fileHashes(harness.a), harness.aBefore, 'A must not be modified');
});

test('exported envs projection carries no credentials and the wrapper is the real template', (t) => {
  const harness = createHarness(t, 'gpt', gptReference);
  const envs = readFileSync(join(harness.hud, 'envs.json'), 'utf8');
  for (const secret of [GPT_TOKEN, GPT_ACCOUNT, GLM_KEY, CLINE_KEY]) {
    assert.ok(!envs.includes(secret), 'public projection must not contain credentials');
  }
  assert.ok(harness.wrapper.includes('gpt-usage-provider.mjs'));
  const referenceWrapper = readFileSync(join(PROVIDERS, 'gpt', 'fetch.sh'), 'utf8').replaceAll('{SLUG}', 'gpt');
  assert.equal(harness.wrapper, referenceWrapper);
  assert.notEqual(statSync(harness.wrapperPath).mode & 0o111, 0, 'wrapper must stay executable');
  assert.ok(!existsSync(join(harness.root, 'claude-config', 'settings.json')));
});
