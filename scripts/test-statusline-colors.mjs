import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const script = fileURLToPath(new URL('../Sources/TokenHUD/mjs/statusline.mjs', import.meta.url));
function render(colorfgbg, legacy = false) {
  const root = mkdtempSync(join(tmpdir(), 'tokenhud-hud-colors-'));
  try {
    const hud = join(root, 'hud');
    mkdirSync(hud);
    const cache = join(hud, 'fixture-cache.json');
    writeFileSync(cache, JSON.stringify({ generatedAt: Date.now(), stale: true,
      five_hour: { used_percentage: 12 }, seven_day: { used_percentage: 95 } }));
    writeFileSync(join(hud, 'envs.json'), JSON.stringify({ 'personal-glm': {
      label: '个人 GLM', cache, buckets: { five_hour: '5h', seven_day: '周' } } }));
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
