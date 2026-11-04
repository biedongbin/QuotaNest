import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

function run(name, auth, response, inspectReads = false) {
  const root = mkdtempSync(join(tmpdir(), 'tokenhud-inherit-auth-'));
  try {
    const curl = join(root, 'fake-curl');
    const args = join(root, 'args.txt');
    const config = join(root, 'account.json');
    const login = join(root, 'changed-login.json');
    const competing = join(root, 'competing-auth.json');
    writeFileSync(competing, JSON.stringify({ cookieAuth: 'session=old-cookie-B', queryKey: 'other-account-token-B',
      apiKey: 'other-account-token-B', refreshApiKey: 'other-account-token-B',
      headers: { Authorization: 'Bearer other-account-token-B' }, queryUrl: 'https://other-account.invalid/usage' }));
    writeFileSync(login, JSON.stringify({ auth_mode: 'chatgpt', tokens: { access_token: 'other-account-token-B', account_id: 'account-B' } }));
    writeFileSync(config, JSON.stringify({ ...auth, codexAuthFile: login }));
    writeFileSync(curl, '#!/bin/zsh\nprintf "%s\\n" "$@" > "$ARGS_FILE"\nprintf "%s" "$FIXTURE_RESPONSE"\nif [[ "$*" == *"%{http_code}"* ]]; then printf "\\n200"; fi\n', { mode: 0o700 });
    const script = fileURLToPath(new URL(`../Sources/TokenHUD/mjs/${name}-usage-provider.mjs`, import.meta.url));
    // Observe real adapter reads and reject any fallback to another account's auth file.
    const observer = `import fs from 'node:fs';
      import { syncBuiltinESMExports } from 'node:module';
      const read = fs.readFileSync;
      fs.readFileSync = function(path, ...options) {
        const file = String(path);
        process.stderr.write('FIXTURE_READ:' + JSON.stringify(file) + '\\n');
        if (![process.env.TOKENHUD_AUTH_FILE, process.env.TOKENHUD_CACHE_FILE].includes(file)) {
          throw new Error('Unexpected credential read: ' + file);
        }
        return read.call(this, path, ...options);
      };
      syncBuiltinESMExports();`;
    const preload = inspectReads ? ['--import', `data:text/javascript,${encodeURIComponent(observer)}`] : [];
    const result = spawnSync(process.execPath, [...preload, script], { timeout: 3000, encoding: 'utf8', env: {
      ...process.env, CLAUDE_CONFIG_DIR: root, CODEX_HOME: root, TOKENHUD_HUD_DIR: root,
      TOKENHUD_AUTH_FILE: config, USAGE_AUTH_FILE: competing,
      TOKENHUD_CACHE_FILE: join(root, 'cache.json'), TOKENHUD_STDOUT_ONLY: '1',
      TOKENHUD_QUERY_URL: auth.queryUrl || auth.apiUrl || '',
      TOKENHUD_CURL: curl, ARGS_FILE: args, FIXTURE_RESPONSE: JSON.stringify(response),
    } });
    assert.equal(result.status, 0, result.stderr || result.error?.message);
    if (inspectReads) {
      const reads = result.stderr.split('\n').filter(line => line.startsWith('FIXTURE_READ:'))
        .map(line => JSON.parse(line.slice('FIXTURE_READ:'.length)));
      assert.deepEqual(reads, [config], 'successful inherited query must read only its resolved snapshot');
    }
    return { body: JSON.parse(result.stdout), args: readFileSync(args, 'utf8') };
  } finally { rmSync(root, { recursive: true, force: true }); }
}

test('GLM API Key queries the official plan route with raw Authorization and actual windows', () => {
  const reset = Date.now() + 3600000;
  const { body, args } = run('glm', { tokenhudResolvedAuth: true, apiUrl: 'https://open.bigmodel.cn/api/monitor/usage/quota/limit',
    headers: { Authorization: 'fake-coding-api-key' }, successCode: 200 }, { success: true, data: { limits: [
      { type: 'TOKENS_LIMIT', unit: 3, number: 5, percentage: 12, nextResetTime: reset },
      { type: 'TOKENS_LIMIT', unit: 6, number: 7, percentage: 45, nextResetTime: reset },
      { type: 'TIME_LIMIT', unit: 5, number: 1, percentage: 80 },
    ] } });
  assert.equal(body.error, null);
  assert.equal(body.five_hour.used_percentage, 12);
  assert.equal(body.seven_day.used_percentage, 45);
  assert.equal(body.five_hour.resets_at, Math.floor(reset / 1000));
  assert.equal(body.windows.length, 2, 'MCP tool calls are not a model monthly allowance');
  assert.ok(args.includes('Authorization: fake-coding-api-key'));
  assert.ok(!args.includes('Bearer fake-coding-api-key'));
  assert.ok(args.includes('https://open.bigmodel.cn/api/monitor/usage/quota/limit'));
});

test('GPT inherited query uses the resolved snapshot instead of a subsequently changed CLI login', () => {
  const { body, args } = run('gpt', { authMode: 'auth', tokenhudResolvedAuth: true,
    queryKey: 'snapshot-account-token-A', accountId: 'account-A' }, { rate_limit: {
      primary_window: { used_percent: 12, limit_window_seconds: 18000 },
      secondary_window: { used_percent: 45, limit_window_seconds: 604800 },
    } });
  assert.equal(body.error, null);
  assert.equal(body.five_hour.used_percentage, 12);
  assert.ok(args.includes('Authorization: Bearer snapshot-account-token-A'));
  assert.ok(args.includes('chatgpt-account-id: account-A'));
  assert.ok(!args.includes('other-account-token-B'));
});

for (const fixture of [
  { name: 'cline', url: 'https://api.cline.bot/api/v1/users/me/plan/usage-limits',
    response: { data: { limits: [{ type: 'five_hour', percentUsed: 12 }] } } },
  { name: 'ollama', url: 'https://ollama.com/api/balance',
    response: { included: { session: { remaining_percent: 88 } } } },
  { name: 'oc-go', url: 'https://opencode.ai/zen/go/v1/usage',
    response: { usage: { rolling: { percent: 12 } } } },
]) {
  test(`${fixture.name} inherits snapshot Key A instead of competing environment credentials and old Cookie B`, () => {
    // ProviderQuerySnapshot removes old Cookie/query credentials before populating these shared fields.
    const { body, args } = run(fixture.name, { authMode: 'apikey', tokenhudResolvedAuth: true,
      queryKey: 'base-key-A', apiKey: 'base-key-A', refreshApiKey: 'base-key-A',
      queryUrl: fixture.url, apiUrl: fixture.url, headers: { Authorization: 'Bearer base-key-A' } },
    fixture.response, true);
    assert.equal(body.error, null);
    assert.equal(body.five_hour.used_percentage, 12);
    const argv = args.trimEnd().split('\n');
    const headers = argv.flatMap((value, index) => value === '-H' ? [argv[index + 1]] : []);
    assert.deepEqual(headers.filter(value => /^authorization:/i.test(value)), ['Authorization: Bearer base-key-A']);
    assert.ok(argv.includes(fixture.url), 'request URL must match the supplier declaration');
    assert.equal(argv.filter(value => /^https?:\/\//.test(value)).length, 1);
    assert.ok(!headers.some(value => /^cookie:/i.test(value)));
    for (const other of ['old-cookie-B', 'other-account-token-B', 'other-account.invalid']) {
      assert.ok(!args.includes(other), `must not use competing account ${other}`);
    }
  });
}
