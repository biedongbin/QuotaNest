#!/usr/bin/env node
// 自定义 statusLine：第1行 目录|ctx|模型|分支；第2行 多环境限额(env1 5h·周 | env2 ...)
// 铁律：快、永不崩溃、永不阻塞网络。顶层 try/catch 兜底。
import { execFileSync, spawn } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const HOME = homedir();
const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(HOME, '.claude');
const HUD_DIR = join(CLAUDE_DIR, 'hud');
const GLM_CACHE = join(HUD_DIR, '.glm-usage-cache.json');
const GLM_AUTH = join(HUD_DIR, '.glm-usage-auth.json');
const GPT_CACHE = join(HUD_DIR, '.gpt-usage-cache.json');
const GPT_AUTH = join(HUD_DIR, '.gpt-usage-auth.json');
const OLLAMA_CACHE = join(HUD_DIR, '.ollama-usage-cache.json');
const OLLAMA_AUTH = join(HUD_DIR, '.ollama-usage-auth.json');
const OCG_CACHE = join(HUD_DIR, '.oc-go-usage-cache.json');
const OCG_AUTH = join(HUD_DIR, '.oc-go-usage-auth.json');
const OCG_PROVIDER = join(HUD_DIR, 'oc-go-usage-provider.mjs'); // OC Go 专用：抓 HTML
const OLLAMA_PROVIDER = join(HUD_DIR, 'ollama-usage-provider.mjs'); // Ollama 专用：/api/balance
const GPT_PROVIDER = join(HUD_DIR, 'gpt-usage-provider.mjs'); // GPT 专用：ChatGPT 官方 wham/usage
const CLINE_PROVIDER = join(HUD_DIR, 'cline-usage-provider.mjs'); // Cline 专用：官方 api.cline.bot
const USAGE_PROVIDER = join(HUD_DIR, 'glm-usage-provider.mjs'); // 泛用：USAGE_PROVIDER_NAME=gpt 切换
const GIT_CACHE = join(HUD_DIR, '.git-cache.json');

const GIT_TTL_MS = 30_000;
const USAGE_TTL_MS = 60_000;

// ANSI 颜色
const C = {
  reset: '\x1b[0m', dim: '\x1b[2m',
  red: '\x1b[31m', green: '\x1b[32m', yellow: '\x1b[33m',
  cyan: '\x1b[36m', bYellow: '\x1b[93m', bGreen: '\x1b[92m',
  bRed: '\x1b[91m', bCyan: '\x1b[96m', bBlue: '\x1b[94m', bMagenta: '\x1b[95m', bWhite: '\x1b[97m',
};
const wrap = (c, s) => (s === '' || s == null) ? '' : `${c}${s}${C.reset}`;
const dim = (s) => wrap(C.dim, s);
const SEP = dim(' | ');
const BUCKET_SEP = dim(' · '); // 同一 env 内 5h 与 周之间

async function readStdin() {
  if (process.stdin.isTTY) return {};
  try {
    process.stdin.setEncoding('utf8');
    let raw = '';
    for await (const chunk of process.stdin) {
      raw += chunk;
      if (raw.length > 2_000_000) break;
    }
    raw = raw.trim();
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

function shortCwd(cwd) {
  if (!cwd) return '?';
  if (cwd === HOME) return '~';
  let p = cwd.startsWith(HOME + '/') ? '~' + cwd.slice(HOME.length) : cwd;
  const parts = p.split('/');
  return parts.length <= 3 ? p : '.../' + parts.slice(-2).join('/');
}

// git 分支：进程内 + 文件双层缓存（每次 statusLine 是全新进程，靠文件缓存跨次）
let _gitCache = null;
function getBranch(cwd) {
  if (!cwd) return null;
  if (_gitCache === null) {
    try { _gitCache = JSON.parse(readFileSync(GIT_CACHE, 'utf8')); }
    catch { _gitCache = {}; }
  }
  const now = Date.now();
  const e = _gitCache[cwd];
  if (e && now - e.ts < GIT_TTL_MS) return e.branch || null;
  let branch = null;
  try {
    const out = execFileSync('git', ['branch', '--show-current'], {
      cwd, timeout: 800, stdio: ['ignore', 'pipe', 'ignore'],
    }).toString().trim();
    if (out) branch = out;
  } catch {}
  _gitCache[cwd] = { branch, ts: now };
  try {
    mkdirSync(HUD_DIR, { recursive: true });
    writeFileSync(GIT_CACHE, JSON.stringify(_gitCache));
  } catch {}
  return branch;
}

// 模型名：GLM/DeepSeek 反代下用 env 的真实后端名替换 Claude tier 名
function resolveModel(stdin, env) {
  const disp = (stdin?.model?.display_name || stdin?.model?.id || '').toString().trim();
  const tier = /opus/i.test(disp) ? 'OPUS'
    : /sonnet/i.test(disp) ? 'SONNET'
    : /haiku/i.test(disp) ? 'HAIKU'
    : /fable/i.test(disp) ? 'FABLE' : null;
  if (tier && (env === 'CC-GLM' || env === 'DeepSeek' || env === 'GPT')) {
    const real = process.env[`ANTHROPIC_DEFAULT_${tier}_MODEL_NAME`];
    if (real) return real;
  }
  return disp || '?';
}

function envColor(env) {
  if (env === 'Claude-Max') return C.bMagenta;
  if (env === 'CC-GLM') return C.bCyan;
  if (env === 'DeepSeek') return C.bBlue;
  if (env === 'GPT') return C.bGreen;
  if (env === 'Ollama') return C.bYellow;
  if (env === 'OC-Go') return C.bRed;
  return C.bWhite;
}

// 多环境限额注册表：source=rate_limits 读 stdin；source=cache 读缓存 + fire-and-forget provider
const ENV_REGISTRY = {
  'Claude-Max': { label: 'Max', source: 'rate_limits', buckets: { five_hour: '5h', seven_day: '周' } },
  'CC-GLM':     { label: 'GLM', source: 'cache', cache: GLM_CACHE, auth: GLM_AUTH, spawnEnv: {}, buckets: { five_hour: '5h', seven_day: '周' } },
  'GPT':        { label: 'GPT', source: 'cache', cache: GPT_CACHE, auth: GPT_AUTH, provider: GPT_PROVIDER, buckets: { five_hour: '5h', seven_day: '周' } },
  'Ollama':     { label: 'Ollama', source: 'cache', cache: OLLAMA_CACHE, auth: OLLAMA_AUTH, provider: OLLAMA_PROVIDER, buckets: { five_hour: '5h', seven_day: '周', monthly: '月' } },
  'OC-Go':      { label: 'OC-Go', source: 'cache', cache: OCG_CACHE, auth: OCG_AUTH, provider: OCG_PROVIDER, buckets: { five_hour: '5h', seven_day: '周', monthly: '月' } },
  'Cline':      { label: 'Cline', source: 'cache', cache: join(HUD_DIR, '.cline-usage-cache.json'), auth: join(HUD_DIR, '.cline-usage-auth.json'), provider: CLINE_PROVIDER, buckets: { five_hour: '5h', seven_day: '周' } },
};

// 动态 env 注册: ~/.claude/hud/envs.json (TokenHUD 写出), 条目与内置 registry 同构
// 缺 auth → maybeSpawnUsage 自动跳过 spawn (只读缓存), 与现有逻辑兼容
try {
  const envsJson = JSON.parse(readFileSync(join(HUD_DIR, 'envs.json'), 'utf8'));
  for (const [key, cfg] of Object.entries(envsJson)) {
    if (ENV_REGISTRY[key]) continue; // 内置优先, 不覆盖
    ENV_REGISTRY[key] = {
      label: cfg.label || key,
      source: 'cache',
      cache: cfg.cache, // 绝对路径
      auth: join(HUD_DIR, '.never-exists'), // 不存在 → 不 spawn
      spawnEnv: {},
      buckets: cfg.buckets || { seven_day: '周' },
    };
  }
} catch { /* envs.json 不存在或损坏 → 仅用内置 */ }

// resets_at 按「秒」约定（GLM provider 入缓存前把毫秒÷1000）
function formatResetTime(epochSec) {
  if (!epochSec || typeof epochSec !== 'number') return null;
  const diff = epochSec * 1000 - Date.now();
  if (diff <= 0) return null;
  const totalMin = Math.floor(diff / 60000);
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  const d = Math.floor(h / 24);
  return d > 0 ? `${d}d${h % 24}h` : `${h}h${m}m`;
}

function pctColor(pct) {
  if (pct == null) return C.dim;
  if (pct >= 90) return C.red;
  if (pct >= 70) return C.yellow;
  return C.green;
}

function makeBar(pct, width = 8) {
  const p = Math.min(100, Math.max(0, pct));
  const filled = Math.round((p / 100) * width);
  const empty = width - filled;
  // 进度条填充不用红色（刺眼）：>=70 黄、<70 绿；百分比数字仍走 pctColor 保留红色告警
  const barC = pct >= 70 ? C.yellow : C.green;
  return `[${barC}${'█'.repeat(filled)}${C.dim}${'░'.repeat(empty)}${C.reset}]`;
}

function renderBucket(label, bucket, stale) {
  if (!bucket || bucket.used_percentage == null) return '';
  const pct = Math.round(bucket.used_percentage);
  const color = pctColor(pct);
  let s = `${dim(label + ':')}${makeBar(pct)}${wrap(color, pct + '%')}`;
  const reset = formatResetTime(bucket.resets_at);
  if (reset) s += dim(`(${reset})`);
  if (stale) s += dim('*');
  return s;
}

function readJsonSafe(p) {
  try { return JSON.parse(readFileSync(p, 'utf8')); }
  catch { return null; }
}

// ACCOUNT_ENVS（逗号分隔，多环境）；兼容单值 ACCOUNT_ENV
// 只读 settings.json，不读进程环境变量：env 移除/为空 → 一个也不显示
function readAccountEnvs() {
  try {
    const s = JSON.parse(readFileSync(join(CLAUDE_DIR, 'settings.json'), 'utf8'));
    const v = s?.env?.ACCOUNT_ENVS || s?.env?.ACCOUNT_ENV;
    if (!v) return [];
    return String(v).split(',').map(x => x.trim()).filter(Boolean);
  } catch { return []; }
}

function usageFresh(cache) {
  return !!(cache && cache.generatedAt && Date.now() - cache.generatedAt < USAGE_TTL_MS);
}

function maybeSpawnUsage(cache, authFile, spawnEnv = {}, providerPath = USAGE_PROVIDER) {
  if (usageFresh(cache)) return;
  try { readFileSync(authFile, 'utf8'); } catch { return; } // auth 文件不存在不 spawn
  try {
    const child = spawn(process.execPath, [providerPath], {
      stdio: 'ignore', detached: true,
      env: { ...process.env, ...spawnEnv },
    });
    child.unref();
  } catch {}
}

function ctxBar(ctxPct) {
  if (typeof ctxPct === 'number' && !Number.isNaN(ctxPct)) {
    const p = Math.round(ctxPct);
    return `${dim('ctx:')}${makeBar(p)}${wrap(pctColor(p), p + '%')}`;
  }
  return `${dim('ctx:')}[${C.dim}${'░'.repeat(8)}${C.reset}]${dim('--%')}`;
}

// 单 env 限额段：label + 桶(5h · 周 · 月)；未知 env 返回空串跳过
function renderEnvQuota(envKey, stdin) {
  const cfg = ENV_REGISTRY[envKey];
  if (!cfg) return '';
  const labelSeg = wrap(envColor(envKey), cfg.label);
  let fiveHour = null, sevenDay = null, monthly = null, stale = false, error = null;

  if (cfg.source === 'rate_limits') {
    const rl = stdin?.rate_limits || {};
    fiveHour = rl.five_hour;
    sevenDay = rl.seven_day;
  } else {
    const cache = readJsonSafe(cfg.cache);
    if (cache?.error === 'auth') error = 'auth';
    else if (cache?.error) error = String(cache.error);
    fiveHour = cache?.five_hour || null;
    sevenDay = cache?.seven_day || null;
    monthly = cache?.monthly || null;
    stale = !usageFresh(cache);
    maybeSpawnUsage(cache, cfg.auth, cfg.spawnEnv, cfg.provider || USAGE_PROVIDER);
  }

  if (error === 'auth') return `${labelSeg} ${wrap(C.yellow, '需登录')}`;
  const buckets = [];
  if (cfg.buckets.five_hour && fiveHour?.used_percentage != null) {
    buckets.push(renderBucket(cfg.buckets.five_hour, fiveHour, stale));
  }
  if (cfg.buckets.seven_day && sevenDay?.used_percentage != null) {
    buckets.push(renderBucket(cfg.buckets.seven_day, sevenDay, stale));
  }
  if (cfg.buckets.monthly && monthly?.used_percentage != null) {
    buckets.push(renderBucket(cfg.buckets.monthly, monthly, stale));
  }
  if (buckets.length) return `${labelSeg} ${buckets.join(BUCKET_SEP)}`;
  if (error) return `${labelSeg} ${dim(error)}`;
  return `${labelSeg} ${dim(cfg.source === 'cache' ? '加载中' : '—')}`;
}

// 第1行：目录 | ctx | 模型 | 分支
function buildLine1(stdin, env) {
  const cwd = stdin?.workspace?.current_dir || stdin?.cwd || process.cwd();
  const parts = [wrap(C.cyan, shortCwd(cwd)), ctxBar(stdin?.context_window?.used_percentage)];
  const model = resolveModel(stdin, env);
  if (model && model !== '?') parts.push(wrap(C.bYellow, model));
  const br = getBranch(cwd);
  if (br) parts.push(wrap(C.bGreen, br));
  return parts.join(SEP);
}

// 第2行：env1 限额 | env2 限额 | ...（每行最多 2 个供应商，超出换行）
function buildLine2(stdin, envs) {
  const segs = envs.map(e => renderEnvQuota(e, stdin)).filter(Boolean);
  const lines = [];
  for (let i = 0; i < segs.length; i += 2) {
    lines.push(segs.slice(i, i + 2).join(SEP));
  }
  return lines.join('\n');
}

async function main() {
  const stdin = await readStdin();
  const envs = readAccountEnvs();
  const primaryEnv = envs[0] || null; // 首个 env 决定模型名替换
  let line1, line2;
  try { line1 = buildLine1(stdin, primaryEnv); } catch { line1 = wrap(C.cyan, shortCwd(stdin?.cwd)); }
  try { line2 = buildLine2(stdin, envs); } catch { /* 留空 */ }
  process.stdout.write(line1 + '\n' + line2);
}

main().catch(() => process.stdout.write('statusline err'));
