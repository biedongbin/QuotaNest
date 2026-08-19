# TokenHUD — 多供应商 Token 余额菜单栏 App 设计

日期：2026-08-19
状态：已与用户确认方向

## 背景

现有 `~/.claude/hud/` 体系通过 statusline 脚本显示多家 AI 供应商用量：

- 4 个缓存型供应商，各有已验证的 provider 脚本：
  - CC-GLM → `glm-usage-provider.mjs`（泛用，`USAGE_PROVIDER_NAME=glm`）
  - GPT → `glm-usage-provider.mjs`（`USAGE_PROVIDER_NAME=gpt`）
  - Ollama → `glm-usage-provider.mjs`（`USAGE_PROVIDER_NAME=ollama`，直连 `https://ollama.com/api/usage`）
  - OC-Go → `oc-go-usage-provider.mjs`（curl 抓 HTML SSR，TLS1.2）
- 配置在 `~/.claude/hud/.*-usage-auth.json`，缓存在 `.*-usage-cache.json`，TTL 60s
- statusline 每次渲染时 fire-and-forget spawn provider 刷新缓存

需求：一个常驻可见的 Mac App——菜单栏图标 + 下拉明细 + 可固定在桌面顶层的悬浮窗。

## 目标

1. 菜单栏图标显示最紧张一家的用量百分比
2. 下拉面板显示供应商各桶（5h/周/月）进度条与重置倒计时
3. 可置顶悬浮窗（迷你条形态，可展开，可拖动，位置记忆）
4. 数据层复用现有 node provider 脚本（内置 4 家零移植）
5. UI 添加自定义供应商（模板制，one-api / OpenAI 兼容先行）
6. 一键写入 Claude Code HUD（statusline 动态注册，无需改 statusline 源码）
7. `swift build` + 脚本打包 `.app`，不依赖 Xcode GUI

## 非目标

- Claude-Max 支持（数据在 Claude Code stdin 里，暂缓；如后续要，statusline 顺写一份共享缓存即可）
- 上架/分发（自用，ad-hoc 签名）
- 用量历史趋势
- 自定义供应商的任意 JSON 字段映射 UI（高级用户直接改 providers.json）

## 技术栈

- Swift 5.9+ / SwiftUI，macOS 14+
- `MenuBarExtra`（菜单栏）+ `NSPanel`（悬浮窗）
- SwiftPM `swift build` 产出可执行文件，打包脚本拼 `.app` bundle

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
│    内置 4 家 (只读展示) + 自定义供应商 CRUD + 写入 HUD 按钮
│
└─ DataEngine (ObservableObject)
     Timer 60s tick → refresh()
     内置家: cache fresh? skip : Process(zsh -c "<node> provider.mjs") 等待 (≤15s)
     自定义家: cache fresh? skip : 模板 fetcher (URLSession, 双端点) 等待 (≤10s)
     → 写同构 .{name}-usage-cache.json → 重读全部缓存 → @Published state
```

## 组件

### 供应商两类（Models.swift）

**内置家**（硬编码 4 家，走 node provider）：

```swift
struct ProviderSpec {
  let name: String        // "CC-GLM" / "GPT" / "Ollama" / "OC-Go"
  let label: String       // "GLM" / "GPT" / "Ol" / "OC"
  let cacheFile: String   // ~/.claude/hud/.{name}-usage-cache.json
  let spawn: SpawnSpec    // 脚本路径 + 额外 env
}
```

spawn 命令与 statusline 现有逻辑逐字一致：

- GLM/GPT/Ollama：`<nodeAbsPath> ~/.claude/hud/glm-usage-provider.mjs`，env 加 `USAGE_PROVIDER_NAME=<name>`
- OC-Go：`<nodeAbsPath> ~/.claude/hud/oc-go-usage-provider.mjs`

**自定义家**（providers.json 持久化，走 Swift fetcher）：

```swift
struct CustomProvider: Codable {
  let name: String        // env key, 如 "my-relay"
  let label: String       // 显示名
  let template: String    // "one-api" (后续可扩)
  let baseURL: String     // 如 https://relay.example.com
  let apiKey: String      // 明文存储, 与现有 auth json 同级安全
}
```

存 `~/Library/Application Support/TokenHUD/providers.json`。

### one-api 模板 fetcher（CustomFetchers.swift）

one-api / new-api 系（国内反代站主流）双端点：

1. `GET {base}/v1/dashboard/billing/subscription`，`Authorization: Bearer <key>` → 总额度（`hard_quota` 或 `total_granted`，美元）
2. `GET {base}/v1/dashboard/billing/usage?start_date=<月初>&end_date=<明日>` → `total_usage`（已用美元）

映射：`used% = total_usage / quota * 100`，写入缓存 `seven_day` 桶（语义：计费周期用量），无 resets_at。

新模板 = 新 enum case + 新 fetch 函数，模板机制即扩展点。

### 缓存结构（解码目标，与现有 json 对齐）

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

（CodingKeys snake_case 映射；OC-Go 缓存同构，无 monthly 的家该字段为 nil）

### NodePath 探测（ProviderRunner.swift）

GUI App 无 shell PATH，node 必须绝对路径：

1. UserDefaults 已存路径且存在 → 用之
2. glob `~/.nvm/versions/node/*/bin/node` 取版本号最大者
3. 兜底 `/usr/local/bin/node`、`/opt/homebrew/bin/node`
4. 都失败 → 状态栏显示错误 + 菜单里给"手动指定 node 路径"入口（open panel，存 UserDefaults）

### 一键写入 Claude Code HUD（HUDSync.swift）

前置：`statusline.mjs` 一次性改造（~15 行）——启动时读 `~/.claude/hud/envs.json` 合并进 `ENV_REGISTRY`，让 statusline 支持动态 env 注册。envs.json 条目字段与内置 registry 同构：

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
2. 更新 `settings.json` 的 `env.ACCOUNT_ENVS`（合并 env key，幂等）
3. 立即触发一次自定义家 fetch，确保缓存存在

statusline 下次渲染即生效（每个 statusline 进程全新启动，无缓存态问题）。已删除/禁用的自定义家同步从 envs.json 与 ACCOUNT_ENVS 移除。

注意：App 不开时自定义家缓存不更新，statusline 显示 stale 值（带 `*`）。内置 4 家不受影响（statusline 自己会 spawn provider）。

### 错误处理

- provider 失败：缓存 json 里自带 `error` + stale 值，App 原样展示（"需登录" / 网络错误 dim 文本），上一次成功值照常显示
- 全部缓存缺失（首次运行且断网）：菜单显示"加载中"
- spawn 超时 15s 强杀，标记 error
- App 层面永不 crash：数据解码失败 → 该家置 error，不影响其他家

### 状态语义（与 statusline 对齐）

- used% ≥90 红、≥70 黄、否则绿
- `error == "auth"` → 黄色"需登录"
- `stale == true` 或 generatedAt 超 60s → 数值后加 `*`
- resets_at 未来时间 → `(2h13m)` 格式倒计时

## 打包

`scripts/package.sh`：

1. `swift build -c release`
2. 拼 `TokenHUD.app/`：`Contents/MacOS/TokenHUD` + `Info.plist`（LSUIElement、NSUserNotificationsUsageDescription 不需要）+ `PkgInfo`
3. `codesign --force --deep -s - TokenHUD.app`（ad-hoc）
4. 拷到 `~/Applications/`（不覆盖正在运行的副本前先提示）

## 测试

- 逻辑层（百分比→颜色、倒计时格式、缓存解码、node 探测序、one-api 双端点响应解析、envs.json/ACCOUNT_ENVS 合并幂等性）用 `swift test` 单测，纯函数无 mock
- spawn/端到端：手动跑 `TokenHUD.app` 对着现有缓存验证（供应商接口无法在 CI mock，人工验收）

## 项目结构

```
~/workspace_private/token-hud/
├─ Package.swift
├─ Sources/TokenHUD/
│  ├─ TokenHUDApp.swift      // @main, MenuBarExtra + Panel/Window 管理
│  ├─ Models.swift           // ProviderSpec / CustomProvider / UsageCache / Bucket
│  ├─ ProviderRunner.swift   // node 探测 + Process spawn
│  ├─ CustomFetchers.swift   // one-api 模板 fetcher (URLSession)
│  ├─ DataEngine.swift       // Timer + 缓存读写 + @Published
│  ├─ HUDSync.swift          // envs.json + ACCOUNT_ENVS 写入
│  ├─ MenuBarView.swift      // 下拉面板 UI
│  ├─ FloatingPanel.swift    // NSPanel 子类 + 配置
│  ├─ FloatingView.swift     // 悬浮窗 UI (迷你条/展开)
│  └─ SettingsView.swift     // 供应商管理 + 添加表单 + 写入按钮
├─ Tests/TokenHUDTests/      // 纯函数单测
├─ scripts/package.sh
└─ docs/superpowers/specs/   // 本文档
```

## 决策记录

- **Swift → zsh → node 而非 Swift 直连（内置家）**：现有 provider 已验证（GLM TLS 风控、OC-Go TLS1.2 抓 HTML 等），零移植零重验；改供应商逻辑不动 App。
- **自定义家 Swift 直连而非走 node**：one-api 模板需双端点合并，泛用 provider 只支持单请求；扩 node 脚本比 Swift 40 行更贵。自定义家写同构缓存，statusline 端零感知。
- **共享缓存而非独立获取**：与 statusline 天然去重（TTL 内只 fetch 一次），互不干扰。
- **statusline 配置化（envs.json）而非 App 改写 statusline 源码**：改写源码脏且易冲突；一次 ~15 行改造后 App 只写配置。
- **非activating 悬浮窗**：点击悬浮窗不抢走当前焦点，作为桌面 HUD 是正确行为。
- **apiKey 明文 json**：与现有 `.*-usage-auth.json` 同级安全（同机同用户明文），Keychain 属过度工程，自用不做。
