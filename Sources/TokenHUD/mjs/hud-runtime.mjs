// Public configuration and display helpers shared by the independent HUD workers.
import { createHash, randomUUID } from 'node:crypto';
import { join, resolve, dirname } from 'node:path';
import { mkdirSync, readdirSync, readFileSync, writeFileSync, unlinkSync, statSync } from 'node:fs';

export const HUD_TTL_MS = 60_000;
export function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  }
  return value;
}
export const digest = value => createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
export const entryRevision = entry => digest(entry);
export function hudCachePath(directory, slug) {
  if (typeof slug !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(slug)) throw new Error('hud-config');
  return join(directory, `.${slug}-hud-cache.json`);
}
export function timestampFresh(timestamp, now = Date.now()) {
  return Number.isFinite(timestamp) && timestamp <= now && now - timestamp < HUD_TTL_MS;
}
export function usageFresh(cache, now = Date.now()) {
  return timestampFresh(cache?.generatedAt, now);
}
export function attemptFresh(cache, now = Date.now()) {
  const attempted = cache?.lastAttemptAt ?? cache?.generatedAt;
  return timestampFresh(attempted, now);
}
export const HUD_ERRORS = Object.freeze({
  'source-identity': '来源账号已变化，请重新写入 HUD',
  'source-missing': '来源记录不可用',
  'source-format': '来源凭证格式无效',
  'source-unsupported': '此来源暂不支持',
  'source-changed': '凭证已更新，稍后重试',
  'auth': '需登录',
  'no-auth': '缺少可用凭证',
  'ratelimit': '查询限流',
  'network': '查询失败',
  'parse': '用量响应无效',
  'no-query': '未配置用量查询',
  'hud-config': 'HUD 配置无效，请重新写入',
  'hud-spawn': '无法启动查询脚本',
  'fetch': '查询失败',
});
export const safeError = code => Object.hasOwn(HUD_ERRORS, code) ? code : 'fetch';

// Nonblocking Lamport bakery lock on a local filesystem. The directory is stable:
// never rename/remove it. Every acquisition owns a unique pathname for its entire
// lifetime, so stale cleanup and late release cannot unlink a successor's claim.
// A zero/partial ticket means "choosing"; contenders withdraw instead of waiting.
export function acquireLock(rawDirectory, observe = () => {}) {
  const directory = resolve(rawDirectory);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const alive = pid => {
    try { process.kill(pid, 0); return true; }
    catch (error) { return error.code !== 'ESRCH'; }
  };
  // Respect an old-version worker still running during an explicit export.
  const legacyPath = join(directory, 'owner.json');
  const legacyRecent = () => {
    try { return Date.now() - statSync(legacyPath).mtimeMs < HUD_TTL_MS; }
    catch (error) { return error.code !== 'ENOENT'; }
  };
  try {
    const legacy = JSON.parse(readFileSync(legacyPath, 'utf8'));
    if (Number.isInteger(legacy?.pid) && legacy.pid > 0) {
      if (alive(legacy.pid)) return null;
    } else if (legacyRecent()) return null;
  } catch (error) { if (error.code !== 'ENOENT' && legacyRecent()) return null; }
  const name = `${process.pid}-${randomUUID()}.claim`;
  const own = join(directory, name);
  const remove = path => {
    if (dirname(path) !== directory || !path.endsWith('.claim')) throw new Error('hud-config');
    try { unlinkSync(path); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  };
  let released = false;
  const release = () => { if (!released) { remove(own); released = true; } };
  const tickets = () => {
    const result = [];
    for (const entry of readdirSync(directory)) {
      const match = /^([1-9][0-9]*)-[a-zA-Z0-9-]+\.claim$/.exec(entry);
      if (!match || entry === name) continue;
      const path = join(directory, entry);
      // UUID names are never reused. Only a confirmed dead process may be reaped.
      if (!alive(Number(match[1]))) { observe('reaping', path); remove(path); continue; }
      try {
        const ticket = Number(readFileSync(path, 'utf8'));
        result.push([entry, Number.isSafeInteger(ticket) && ticket > 0 ? ticket : 0]);
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    return result;
  };
  try {
    writeFileSync(own, '0', { flag: 'wx', mode: 0o600 });
    observe('choosing', own);
    const number = Math.max(0, ...tickets().map(([, ticket]) => ticket)) + 1;
    if (!Number.isSafeInteger(number)) { release(); return null; }
    writeFileSync(own, String(number));
    observe('numbered', own);
    for (const [other, ticket] of tickets()) {
      if (ticket === 0 || ticket < number || (ticket === number && other < name)) {
        release(); return null;
      }
    }
    return release;
  } catch (error) { release(); throw error; }
}
