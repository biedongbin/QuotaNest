import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, statSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const script = fileURLToPath(new URL('../Sources/TokenHUD/mjs/statusline.mjs', import.meta.url));
function render(change) {
  const root = mkdtempSync(join(tmpdir(), 'tokenhud-ref-hud-'));
  try {
    const hud = join(root, 'hud');
    mkdirSync(hud);
    const source = join(root, 'fixture.sqlite');
    const wal = source + '-wal';
    // Intentionally invalid source bytes: the HUD must only stat paths, never parse credentials or SQLite.
    writeFileSync(source, 'fixture-private-value-invalid-db');
    const baseline = new Date(Date.now() - 5000);
    utimesSync(source, baseline, baseline);
    const cacheFile = join(hud, 'cache.json');
    const cache = { generatedAt: Date.now(), sourceRevision: 'fixture-digest', seven_day: { used_percentage: 73 } };
    const dependencies = { [source]: statSync(source).mtimeMs, [wal]: 0 };
    change?.({ source, wal, cache, dependencies });
    writeFileSync(cacheFile, JSON.stringify(cache));
    writeFileSync(join(hud, 'envs.json'), JSON.stringify({ fixture: {
      label: 'Fixture', source: 'cache', cache: cacheFile, authSourceFile: source,
      sourceReferenceDependencies: dependencies, buckets: { seven_day: '周' },
    } }));
    writeFileSync(join(root, 'settings.json'), JSON.stringify({ env: { ACCOUNT_ENVS: 'fixture' } }));
    const run = spawnSync(process.execPath, [script], { cwd: root, timeout: 3000, encoding: 'utf8',
      env: { ...process.env, CLAUDE_CONFIG_DIR: root, TOKENHUD_HUD_DIR: hud },
      input: JSON.stringify({ cwd: root, model: { display_name: 'fixture' } }) });
    assert.equal(run.status, 0, run.stderr || run.error?.message);
    assert.ok(!run.stdout.includes('fixture-private-value'));
    return run.stdout;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test('unchanged referenced source renders a bound cache without parsing source bytes', () => {
  assert.match(render(), /73%/);
});
test('successful App query and refreshed dependency projection recover after rotation', () => {
  const output = render(({ source, cache, dependencies }) => {
    writeFileSync(source, 'changed-fixture');
    const queried = new Date(Date.now() - 1000);
    utimesSync(source, queried, queried);
    dependencies[source] = statSync(source).mtimeMs;
    cache.sourceRevision = 'fixture-digest-B';
    cache.generatedAt = Date.now();
  });
  assert.match(output, /73%/);
  assert.doesNotMatch(output, /来源变更/);
});
for (const [name, change] of [
  ['unstamped legacy cache', ({ cache }) => { delete cache.sourceRevision; }],
  ['changed source', ({ source }) => { writeFileSync(source, 'changed-fixture'); }],
  ['deleted source', ({ source }) => { rmSync(source); }],
  ['new SQLite WAL', ({ wal }) => { writeFileSync(wal, 'fixture-wal'); }],
  ['old cache paired with freshly synced dependencies', ({ source, cache, dependencies }) => {
    cache.generatedAt = Date.now() - 10000;
    dependencies[source] = statSync(source).mtimeMs;
  }],
  ['WAL disappears since sync', ({ wal, dependencies }) => {
    dependencies[wal] = Date.now() - 5000;
  }],
]) {
  test(name + ' hides previous identity quota and waits for App query', () => {
    const output = render(change);
    assert.match(output, /来源变更，待查询/);
    assert.doesNotMatch(output, /73%/);
  });
}
