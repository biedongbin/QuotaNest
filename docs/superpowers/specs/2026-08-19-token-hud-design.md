# TokenHUD — 多供应商 Token 余额菜单栏 App 设计

日期：2026-08-19
状态：已与用户确认方向（插件式供应商架构）

## 背景

现有 `~/.claude/hud/` 体系通过 statusline 脚本显示多家 AI 供应商用量：

- 4 个缓存型供应商，各有已验证的 node provider 脚本：
  - CC-GLM → `glm-usage-provider.mjs`（泛用，`USAGE_PROVIDER_NAME=glm`）
  - GPT → `glm-usage-provider.mjs`（`USAGE_PROVIDER_NAME=gpt`）
  - Ollama → `glm-usage-provider.mjs`（`USAGE_PROVIDER_NAME=ollama`，直连 `https://ollama.com/api/usage`）
  - OC-Go → `oc-go-usage-provider.mjs`（curl 抓 HTML SSR，TLS1.2）
- 配置在 `~/.claude/hud/.*-usage-auth.json`，缓存在 `.*-usage-cache.json`，TTL 60s
- statusline 每次渲染时 fire-and-forget spawn provider 刷新缓存

需求：一个常驻可见的 Mac App——菜单栏图标 + 下拉明细 + 可固定在桌面顶层的悬浮窗；支持 UI 添加自定义供应商；一键写入 Claude Code HUD。

## 目标

1. 菜单栏图标显示最紧张一家的用量百分比
2. 下拉面板显示供应商各桶（5h/周/月）进度条与重置倒计时
3. 可置顶悬浮窗（迷你条形态，可展开，可拖动，位置记忆）
4. **插件式供应商架构**：每家供应商一个子目录（manifest + 取数脚本），主框架自动扫描加载，加供应商不改主框架
5. UI 添加自定义供应商（one-api / OpenAI 兼容模板先行）
6. 一键写入 Claude Code HUD（statusline 动态注册）
7. `swift build` + 脚本打包 `.app`，不依赖 Xcode GUI

## 非目标

- Claude-Max 支持（数据在 Claude Code stdin 里，暂缓）
- 上架/分发（自用，ad-hoc 签名）
- 用量历史趋势
- 自定义供应商的任意字段映射 UI（高级用户直接改插件目录里的文件）

## 核心抽象：供应商插件

每家供应商 = 一个目录：

```
providers/<name>/
├─ manifest.json    // 声明 + 取数方式
└─ fetch.sh         // 可执行取数脚本
```

**manifest.json**：

```json
{
  "name": "CC-GLM",            // env key（写入 ACCOUNT_ENVS 用）
  "label": "GLM",              // UI 短名
  "fetch": "./fetch.sh",       // 相对目录; stdout 必须输出 UsageCache json
  "intervalSec": 60,           // 可选, 默认 60
  "buckets": { "five_hour": "5h", "seven_day": "周" },
  "enabled": true              // 可选, 默认 true
}
```

**fetch.sh 契约**：

- 框架 spawn 时注入 `TOKENHUD_NODE`（node 绝对路径，框架启动时探测）
- stdout 输出 UsageCache 同构 json（下见），退出码 0；失败退出非 0（框架保留旧值标 stale）
- 可手动执行调试：`TOKENHUD_NODE=$(which node) ./fetch.sh`

**插件目录两处来源，Registry 合并加载**：

1. App bundle 内（SwiftPM resources）：内置 glm / gpt / ollama / opencode-go
2. `~/Library/Application Support/TokenHUD/providers/`：自定义家（UI 生成或手写）

同名时用户目录优先（可覆盖内置定义）。

## 架构

```
TokenHUD.app (LSUIElement=true, 无 Dock 图标)
│
├─ MenuBarExtra
│    图标: 全部桶中最高 used% (最紧张者)
│    下拉: 供应商明细 + 悬浮窗开关 + 立即刷新 + 供应商管理 + 退出
│
├─ FloatingPanel (NSPanel)
│    styleMask: .nonactivatingPanel (不抢焦点)
│    level: .floating (置顶)
│    isMovableByWindowBackground = true
│    形态: 迷你条 (单行: GLM 47 │ Ol 28 │ OC 61)
│          点击展开 → 各桶进度条 + 倒计时
│    位置持久化: UserDefaults (frame)
│
├─ SettingsWindow (普通 SwiftUI Window)
│    供应商列表(内置+自定义, 插件目录渲染) + 添加向导 + 写入 HUD 按钮
│
└─ DataEngine (ObservableObject)
     启动: ProviderRegistry 扫描两处插件目录 → [PluginProvider]
     Timer 每 10s tick: 对每家, 缓存新鲜(< intervalSec)? 跳过 : spawn fetch.sh (≤15s)
     spawn 成功: stdout json → 写 ~/.claude/hud/.{key}-usage-cache.json (statusline 共享)
              → 更新 @Published state
     spawn 失败: 保留旧值 + stale 标记
```

## 组件

### UsageCache（框架与脚本之间的数据契约）

```swift
struct UsageCache: Codable {
  let generatedAt: Double?      // ms epoch
  let fiveHour: Bucket?
  let sevenDay: Bucket?
  let monthly: Bucket?
  let error: String?
  let stale: Bool?
}
struct Bucket: Codable {
  let usedPercentage: Double?   // used_percentage
  let resetsAt: Int?            // resets_at, 秒
}
```

（CodingKeys snake_case；fetch.sh 输出与 node provider 写的缓存同构，statusline 端零改动）

### ProviderRegistry（扫描与加载）

- 扫描 bundle（`Bundle.module`）与 Application Support 两处 `providers/*/manifest.json`
- 解析 → `PluginProvider { manifest, dir }`；目录名即插件 key（URL slug 约束：`[a-z0-9-]`）
- 校验失败（manifest 缺字段 / fetch 不可执行）→ 跳过并在设置页显示装载错误

### 内置 4 家 fetch.sh（照搬现有已验证逻辑）

```bash
# providers/glm/fetch.sh
#!/bin/zsh
USAGE_PROVIDER_NAME=glm "${TOKENHUD_NODE:?no node}" ~/.claude/hud/glm-usage-provider.mjs >/dev/null 2>&1
cat ~/.claude/hud/.glm-usage-cache.json
```

（gpt / ollama 换 `USAGE_PROVIDER_NAME`；opencode-go 换 `oc-go-usage-provider.mjs` + 对应缓存文件）

### 自定义供应商（one-api 模板 = 生成插件目录的向导）

Settings 添加表单：名称 / baseURL / apiKey（SecureField）/ [测试连接]。提交时生成：

```
~/Library/Application Support/TokenHUD/providers/<slug>/
├─ manifest.json   // buckets: {"seven_day":"周"}
└─ fetch.sh        // curl 双端点 + python3 合并 (系统自带, 零外部依赖)
```

one-api 双端点取数（fetch.sh 内实现）：

1. `GET {base}/v1/dashboard/billing/subscription`，`Authorization: Bearer <key>` → 总额度（`hard_quota` 或 `total_granted`，美元）
2. `GET {base}/v1/dashboard/billing/usage?start_date=<月初>&end_date=<明日>` → `total_usage`（已用美元）
3. `used% = total_usage / quota * 100` → 输出 `{ "seven_day": { "used_percentage": N } }`

新模板（如 Ollama Cloud 他人账号）= App 内加一个向导类型，仍只生成脚本，主框架不变。

### 一键写入 Claude Code HUD（HUDSync.swift）

前置：`statusline.mjs` 一次性改造（~15 行）——启动时读 `~/.claude/hud/envs.json` 合并进 `ENV_REGISTRY`，让 statusline 支持动态 env 注册。envs.json 条目与内置 registry 同构：

```json
{
  "my-relay": { "label": "Relay", "source": "cache",
    "cache": "~/.claude/hud/.my-relay-usage-cache.json",
    "buckets": { "seven_day": "周" } }
}
```

自定义家不需要 `auth`/`provider` 字段（缓存由 App 负责刷，statusline 只读缓存；`maybeSpawnUsage` 见 auth 缺失自动跳过 spawn，现有逻辑已兼容）。

「写入 Claude Code HUD」做三件事：

1. 写/合并 `~/.claude/hud/envs.json`（注册全部启用的自定义 env）
2. 更新 `settings.json` 的 `env.ACCOUNT_ENVS`（合并 key，幂等）
3. 立即触发一次全部自定义家 fetch，确保缓存存在

statusline 下次渲染即生效（每个 statusline 进程全新启动，无缓存态问题）。已删除/禁用的家同步从 envs.json 与 ACCOUNT_ENVS 移除。

注意：App 不开时自定义家缓存不更新，statusline 显示 stale 值（带 `*`）。内置家不受影响（statusline 自己会 spawn node provider）。

### NodePath 探测（ProviderRunner.swift）

GUI App 无 shell PATH，node 必须绝对路径：

1. UserDefaults 已存路径且存在 → 用之
2. glob `~/.nvm/versions/node/*/bin/node` 取版本号最大者
3. 兜底 `/usr/local/bin/node`、`/opt/homebrew/bin/node`
4. 都失败 → 菜单显示错误 + 设置页"手动指定 node 路径"（open panel，存 UserDefaults）

探测结果注入每次 spawn 的 `TOKENHUD_NODE`。

### 状态语义（与 statusline 对齐）

- used% ≥90 红、≥70 黄、否则绿
- `error == "auth"` → 黄色"需登录"
- `stale == true` 或超 intervalSec → 数值后加 `*`
- resets_at 未来时间 → `(2h13m)` 格式倒计时

### 错误处理

- fetch.sh 非 0 退出 / stdout 解析失败：该家保留旧值 + stale，不影响其他家
- 全部无数据（首次运行且失败）：菜单显示"加载中"
- spawn 超时 15s 强杀，标 stale
- App 层面永不 crash：单家失败隔离

## 打包

`scripts/package.sh`：

1. `swift build -c release`
2. 拼 `TokenHUD.app/`：`Contents/MacOS/TokenHUD` + `Contents/Resources/`（含 providers/）+ `Info.plist`（LSUIElement）+ `PkgInfo`
3. `codesign --force --deep -s - TokenHUD.app`（ad-hoc）
4. 拷到 `~/Applications/`（覆盖前提示）

## 测试

- 单测（`swift test`，纯函数无 mock）：缓存解码、百分比→颜色、倒计时格式、node 探测序、one-api 响应解析（fetch.sh 的 python 合并逻辑）、envs.json/ACCOUNT_ENVS 合并幂等性、manifest 解析与坏插件跳过
- 端到端：手动跑 App 对现有缓存验收；`fetch.sh` 手动执行验证各内置家

## 项目结构

```
~/workspace_private/token-hud/
├─ Package.swift
├─ Sources/TokenHUD/
│  ├─ TokenHUDApp.swift        // @main, MenuBarExtra + Panel/Window 管理
│  ├─ Models.swift             // Manifest / UsageCache / Bucket
│  ├─ ProviderRegistry.swift   // 双源扫描 + 校验
│  ├─ ProviderRunner.swift     // node 探测 + fetch.sh spawn (stdout→缓存)
│  ├─ DataEngine.swift         // Timer + @Published
│  ├─ HUDSync.swift            // envs.json + ACCOUNT_ENVS 写入
│  ├─ PluginGenerator.swift    // one-api 向导 → 生成插件目录
│  ├─ ui/
│  │  ├─ MenuBarView.swift
│  │  ├─ FloatingPanel.swift   // NSPanel 子类
│  │  ├─ FloatingView.swift    // 迷你条/展开
│  │  └─ SettingsView.swift    // 供应商管理/添加/写入按钮
├─ Resources/providers/        // SwiftPM resources, 打进 bundle
│  ├─ glm/{manifest.json, fetch.sh}
│  ├─ gpt/{manifest.json, fetch.sh}
│  ├─ ollama/{manifest.json, fetch.sh}
│  └─ opencode-go/{manifest.json, fetch.sh}
├─ Tests/TokenHUDTests/
├─ scripts/package.sh
└─ docs/superpowers/specs/     // 本文档
```

## 决策记录

- **插件式（manifest + fetch.sh）而非 Swift 内置 provider**：满足"供应商代码+配置自包含于子目录、主框架扫描自动加载"；Swift 无动态加载源码能力，脚本即插件是唯一能字面兑现该需求的方式；且现有 node provider 逻辑零移植直接复用。
- **stdout 契约 + 框架写缓存**：脚本无状态、可独立调试；缓存写入（原子性/路径规范）框架统一处理。
- **双源扫描（bundle + 用户目录）、用户覆盖内置**：内置随 App 分发，自定义可插拔，覆盖机制留逃生门。
- **自定义供应商 = 生成插件目录的向导**：自定义与内置最终同构，无平行机制。
- **statusline 配置化（envs.json）而非改写 statusline 源码**：一次 ~15 行改造后 App 只写配置。
- **共享缓存**：与 statusline 天然去重，互不干扰。
- **apiKey 明文（fetch.sh 内嵌 / providers.json 不存在了）**：与现有 `.*-usage-auth.json` 同级安全，Keychain 属过度工程，自用不做。
- **非activating 悬浮窗**：桌面 HUD 正确行为。
