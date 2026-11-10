import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readdirSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import * as runtime from '../Sources/TokenHUD/mjs/hud-runtime.mjs';

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'hud-lock-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return join(root, 'cache.lock');
}
test('lock releases only its unique claim, including repeated late release', t => {
  const path = fixture(t);
  const first = runtime.acquireLock(path);
  assert.equal(typeof first, 'function');
  assert.equal(runtime.acquireLock(path), null);
  first();
  const second = runtime.acquireLock(path);
  assert.equal(typeof second, 'function');
  first();
  assert.equal(runtime.acquireLock(path), null);
  second();
});
test('dead-owner recovery with simultaneous contenders never overlaps critical sections', async t => {
  assert.equal(typeof runtime.acquireLock, 'function');
  const path = fixture(t);
  mkdirSync(path);
  writeFileSync(join(path, 'owner.json'), JSON.stringify({ pid: 2147483647 }));
  // Immutable dead contender from the new protocol, plus legacy dead owner.
  writeFileSync(join(path, '2147483647-dead.claim'), '1');
  const module = new URL('../Sources/TokenHUD/mjs/hud-runtime.mjs', import.meta.url).href;
  const code = `import { acquireLock } from ${JSON.stringify(module)};
    import { mkdirSync, rmdirSync } from 'node:fs';
    import { setTimeout } from 'node:timers/promises';
    for (let i = 0; i < 25; i++) {
      const release = acquireLock(process.argv[1]);
      if (release) {
        mkdirSync(process.argv[1] + '/critical');
        await setTimeout(3);
        rmdirSync(process.argv[1] + '/critical');
        release();
      }
      await setTimeout(2);
    }`;
  await Promise.all(Array.from({ length: 8 }, () => new Promise((done, reject) => {
    const child = spawn(process.execPath, ['--input-type=module', '-e', code, path], { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = ''; child.stderr.on('data', chunk => stderr += chunk);
    child.on('error', reject);
    child.on('exit', status => status === 0 ? done() : reject(new Error(stderr)));
  })));
  assert.equal(readdirSync(path).filter(name => name.endsWith('.claim')).length, 0);
  const release = runtime.acquireLock(path);
  assert.equal(typeof release, 'function'); release();
});

for (const stage of ['choosing', 'numbered']) test(`contender observed during ${stage} cannot acquire`, t => {
  const path = fixture(t);
  let attempted = false;
  const release = runtime.acquireLock(path, event => {
    if (event !== stage) return;
    attempted = true;
    assert.equal(runtime.acquireLock(path), null);
  });
  assert.equal(attempted, true);
  assert.equal(typeof release, 'function'); release();
});
test('two reapers observing one dead claim cannot delete a new live claim', t => {
  const path = fixture(t); mkdirSync(path);
  writeFileSync(join(path, '2147483647-dead.claim'), '1');
  let once = false;
  const successor = join(path, `${process.pid}-0.claim`);
  const release = runtime.acquireLock(path, (event, dead) => {
    if (event !== 'reaping' || once) return;
    once = true;
    // Force a second reaper's unlink and a new live ticket between the first
    // reaper's dead-PID observation and unlink. The equal ticket sorts first.
    rmSync(dead);
    writeFileSync(successor, '1');
  });
  assert.equal(once, true);
  assert.equal(release, null);
  assert.deepEqual(readdirSync(path), [`${process.pid}-0.claim`]);
  assert.equal(runtime.acquireLock(path), null);
  rmSync(successor);
});
test('legacy partial owner is protected briefly and recoverable after grace period', t => {
  const path = fixture(t); mkdirSync(path);
  const owner = join(path, 'owner.json'); writeFileSync(owner, '{"pid":');
  assert.equal(runtime.acquireLock(path), null);
  const old = new Date(Date.now() - 120000); utimesSync(owner, old, old);
  const release = runtime.acquireLock(path);
  assert.equal(typeof release, 'function'); release();
});
