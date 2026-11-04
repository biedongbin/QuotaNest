import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const script = fileURLToPath(new URL('../Sources/TokenHUD/mjs/statusline.mjs', import.meta.url));
function render(colorfgbg, legacy = false, sourceState = null) {
  const root = mkdtempSync(join(tmpdir(), 'tokenhud-hud-colors-'));
  try {
    const hud = join(root, 'hud');
    mkdirSync(hud);
    const cache = join(hud, 'fixture-cache.json');
    writeFileSync(cache, JSON.stringify({ generatedAt: Date.now(), stale: true,
      five_hour: { used_percentage: 12 }, seven_day: { used_percentage: 95 } }));
    const authSourceFile = join(root, 'login.json');
    if (sourceState === 'changed') {
      writeFileSync(authSourceFile, '{"fixture":true}');
      const future = new Date(Date.now() + 5000);
      utimesSync(authSourceFile, future, future);
    }
    writeFileSync(join(hud, 'envs.json'), JSON.stringify({ 'personal-glm': {
      label: '个人 GLM', cache, buckets: { five_hour: '5h', seven_day: '周' },
      source: sourceState === 'api' ? 'api' : 'cache',
      authSourceFile: ['changed', 'missing'].includes(sourceState) ? authSourceFile : undefined } }));
    writeFileSync(join(root, 'settings.json'), JSON.stringify({ env: { ACCOUNT_ENVS: legacy ? 'Claude-Max' : 'personal-glm' } }));
    const run = spawnSync(process.execPath, [script], { cwd: root, timeout: 3000, encoding: 'utf8',
      env: { ...process.env, CLAUDE_CONFIG_DIR: root, TOKENHUD_HUD_DIR: hud, COLORFGBG: colorfgbg },
      input: JSON.stringify({ cwd: root, model: { display_name: 'fixture-model' },
        context_window: { used_percentage: 14 }, rate_limits: { five_hour: { used_percentage: 95 } } }) });
    assert.equal(run.status, 0, run.stderr || run.error?.message);
    assert.doesNotMatch(run.stdout, /undefined/);
    assert.doesNotMatch(run.stdout, /\x1b\[(?:9[0-7]|2)m/, 'HUD must not force bright text or faint opacity');
    return run.stdout;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}
for (const theme of [{ name: 'light', color: '0;15' }, { name: 'dark', color: '15;0' }]) {
  test(`${theme.name}: dynamic account and metadata inherit the terminal foreground`, () => {
    const output = render(theme.color);
    assert.ok(output.includes('\x1b[39m个人 GLM\x1b[0m'));
    assert.ok(output.includes('\x1b[39m5h:'));
    assert.ok(output.includes('\x1b[39m*'));
    assert.ok(output.includes('\x1b[31m95%'), 'critical quota remains red');
  });
}
test('legacy labels use normal theme colors instead of bright variants', () => {
  const output = render('0;15', true);
  assert.ok(output.includes('\x1b[35mMax\x1b[0m'));
  assert.ok(output.includes('\x1b[31m95%'));
});

test('Auth source switch hides the previous account quota even without App refresh', () => {
  const output = render('0;15', false, 'changed');
  assert.ok(output.includes('授权已变化，待查询'));
  assert.ok(!output.includes('95%'));
});
test('Auth logout hides previous quota and asks for login', () => {
  const output = render('0;15', false, 'missing');
  assert.ok(output.includes('需登录'));
  assert.ok(!output.includes('95%'));
});
test('API-only accounts do not pretend to load unavailable quota', () => {
  const output = render('0;15', false, 'api');
  assert.ok(output.includes('仅 API'));
  assert.ok(!output.includes('加载中'));
  assert.ok(!output.includes('95%'));
});
