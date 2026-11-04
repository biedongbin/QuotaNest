#!/usr/bin/env node
// Cross-lane regression: cached account A must never become account B's failed response.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const temp = mkdtempSync(join(tmpdir(), 'tokenhud-catalog-failure-'));
const hud = join(temp, 'hud');
mkdirSync(hud);
const lanes = [
  { module: 'balance', provider: 'deepseek', mode: 'apikey' },
  { module: 'rate', provider: 'opencode-zen', mode: 'apikey' },
  { module: 'coding', provider: 'zai-coding', mode: 'apikey' },
  { module: 'community', provider: 'factory', mode: 'apikey' },
  { module: 'auth', provider: 'claude-code', mode: 'auth' },
  { module: 'account', provider: 'qoder', mode: 'auth', context: { sourceProvider: 'qoder', region: 'intl' } },
  { module: 'desktop', provider: 'workbuddy', mode: 'auth', context: { userId: 'USER_B', domain: 'www.workbuddy.ai' } },
  { module: 'enterprise', provider: 'qwenwork', mode: 'auth' },
  { module: 'workspace', provider: 'raccoon', mode: 'auth' },
];
for (const name of [...lanes.map(lane => `catalog-${lane.module}-provider.mjs`), 'auth-usage-parsers.mjs']) {
  copyFileSync(join(root, 'Sources/TokenHUD/mjs', name), join(hud, name));
}
const curl = join(temp, 'fake-curl.cjs');
writeFileSync(curl, `#!${process.execPath}
const fs = require('node:fs');
fs.appendFileSync(process.env.CURL_LOG, JSON.stringify(process.argv.slice(2)) + '\\n');
process.stdout.write('{"error":"denied"}\\n' + process.env.HTTP_CODE);
`, { mode: 0o700 });
after(() => {
  assert.ok(resolve(temp).startsWith(resolve(tmpdir()) + '/tokenhud-catalog-failure-'));
  rmSync(temp, { recursive: true, force: true });
});

for (const lane of lanes) {
  for (const status of [401, 500]) {
    for (const stdoutOnly of [true, false]) {
      test(`${lane.module}: A cache + B snapshot + HTTP ${status}, stdoutOnly=${stdoutOnly}`, () => {
        const dir = join(temp, `${lane.module}-${status}-${stdoutOnly}`);
        mkdirSync(dir);
        const cache = join(dir, 'cache.json'), snapshot = join(dir, 'snapshot.json'), log = join(dir, 'requests.jsonl');
        const cachedA = JSON.stringify({ generatedAt: 123, account_id: 'ACCOUNT_A', plan: 'PLAN_A',
          windows: [{ label: 'ACCOUNT_A', amount: 73, unit: 'credits', period: 'balance' }],
          five_hour: { used_percentage: 17 }, seven_day: { used_percentage: 29 }, monthly: { used_percentage: 41 } });
        const selectedB = JSON.stringify({ authMode: lane.mode, queryKey: 'SELECTED_TOKEN_B', tokenhudAuthContext: lane.context || {} });
        writeFileSync(cache, cachedA);
        writeFileSync(snapshot, selectedB);
        const wrapper = join(dir, 'fetch.sh');
        writeFileSync(wrapper, readFileSync(join(root, 'Sources/TokenHUD/providers', lane.provider, 'fetch.sh'), 'utf8')
          .replaceAll('{SLUG}', lane.provider + '-account-b'));
        const child = spawnSync('/bin/zsh', [wrapper], {
          encoding: 'utf8', timeout: 5000,
          env: { PATH: process.env.PATH, HOME: dir, TOKENHUD_NODE: process.execPath, TOKENHUD_HUD_DIR: hud,
            TOKENHUD_AUTH_FILE: snapshot, TOKENHUD_CACHE_FILE: cache, TOKENHUD_STDOUT_ONLY: stdoutOnly ? '1' : '0',
            TOKENHUD_CURL: curl, CURL_LOG: log, HTTP_CODE: String(status) },
        });
        assert.equal(child.status, 0, child.stderr || child.error?.message);
        const output = JSON.parse(child.stdout);
        assert.equal(output.error, status === 401 ? 'auth' : 'network');
        assert.equal(output.stale, true);
        assert.ok(output.lastAttemptAt > 123);
        for (const field of ['windows', 'five_hour', 'seven_day', 'monthly', 'generatedAt', 'account_id', 'plan']) {
          assert.equal(Object.hasOwn(output, field), false, `${field}: only the native engine may retain last-good data after identity checks`);
        }
        assert.ok(!child.stdout.includes('ACCOUNT_A') && !child.stdout.includes('SELECTED_TOKEN_B'));
        const requests = readFileSync(log, 'utf8');
        assert.ok(requests.includes('SELECTED_TOKEN_B'), 'must reach fake HTTP using the selected B credential');
        assert.ok(!requests.includes('ACCOUNT_A'));
        assert.equal(readFileSync(snapshot, 'utf8'), selectedB, 'selected credentials remain read-only');
        if (stdoutOnly) assert.equal(readFileSync(cache, 'utf8'), cachedA, 'stdout mode must leave disk cache unchanged');
        else assert.deepEqual(JSON.parse(readFileSync(cache, 'utf8')), output, 'CLI cache contains only the current failure');
      });
    }
  }
}
