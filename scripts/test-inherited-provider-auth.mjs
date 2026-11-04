import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

function run(name, auth, response) {
  const root = mkdtempSync(join(tmpdir(), 'tokenhud-inherit-auth-'));
  try {
    const curl = join(root, 'fake-curl');
    const args = join(root, 'args.txt');
    const config = join(root, 'account.json');
    const login = join(root, 'changed-login.json');
    writeFileSync(login, JSON.stringify({ auth_mode: 'chatgpt', tokens: { access_token: 'other-account-token-B', account_id: 'account-B' } }));
    writeFileSync(config, JSON.stringify({ ...auth, codexAuthFile: login }));
    writeFileSync(curl, '#!/bin/zsh\nprintf "%s\\n" "$@" > "$ARGS_FILE"\nprintf "%s" "$FIXTURE_RESPONSE"\nif [[ "$*" == *"%{http_code}"* ]]; then printf "\\n200"; fi\n', { mode: 0o700 });
    const script = fileURLToPath(new URL(`../Sources/TokenHUD/mjs/${name}-usage-provider.mjs`, import.meta.url));
    const result = spawnSync(process.execPath, [script], { timeout: 3000, encoding: 'utf8', env: {
      ...process.env, CLAUDE_CONFIG_DIR: root, CODEX_HOME: root, TOKENHUD_HUD_DIR: root,
      TOKENHUD_AUTH_FILE: config, TOKENHUD_CACHE_FILE: join(root, 'cache.json'), TOKENHUD_STDOUT_ONLY: '1',
      TOKENHUD_CURL: curl, ARGS_FILE: args, FIXTURE_RESPONSE: JSON.stringify(response),
    } });
    assert.equal(result.status, 0, result.stderr || result.error?.message);
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
