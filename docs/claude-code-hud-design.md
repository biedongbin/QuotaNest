# Claude Code HUD 程序代码架构设计

核对基线：2026-11-09 工作区实现。本文解释 schema v2 的导出、执行、数据契约与兼容边界；产品需求以 [A/B/C 架构与需求契约](abc-architecture-requirements.md) 为准。它是代码设计说明，不是供应商真实网络验收报告。

## 1. 运行边界

C 是由 Claude Code 调用的 Node 状态栏程序，加上按需启动的 Node 查询 worker。Swift 仅负责 B 侧的显式导出；导出后 C 的执行链不包含 QuotaNest 进程、CLI、App bundle 或 B 私有运行时。

```text
导出阶段（只在点击按钮时）
GlobalPages → SettingsModel.syncHUD → DataEngine.exportHUD → HUDSync.sync
                                                        └→ C 的运行包与设置

运行阶段（每次 Claude Code 渲染）
Claude Code stdin + settings → statusline.mjs → 读取 C 缓存 → 输出终端文本
                                      └→ 缺失／过期：启动 detached worker
ref-usage-provider.mjs → source-readers.mjs → A 的指定 JSON／SQLite 记录
                      → 临时认证快照 → providers/<slug>/fetch.sh
                                      → 供应商 mjs 适配器 → 用量 API
                      ← 标准用量结果 ←──────────────────────┘
                      → 校验配置和凭证未变化 → 原子替换 C 缓存
```

渲染进程不等待供应商网络请求完成；worker 的查询结果在下一次渲染读取。所谓“不阻塞网络”不等于整个渲染零阻塞：渲染仍有本地文件读取和最多 800ms 的 Git 分支命令。

## 2. 模块与职责

| 模块 | 关键入口 | 职责 |
| --- | --- | --- |
| [GlobalPages.swift](../Sources/TokenHUD/ui/SettingsCenter/GlobalPages.swift) | 导出按钮 | 提供唯一用户操作及待导出提示 |
| [SettingsModel.swift](../Sources/TokenHUD/ui/SettingsCenter/SettingsModel.swift) | `syncHUD()` | 调用导出并显示成功／失败反馈 |
| [DataEngine.swift](../Sources/TokenHUD/DataEngine.swift) | `exportHUD()`、`markHUDExportNeeded()` | 传递已保存账号及显示选择；本地变更只标记待导出 |
| [HUDSync.swift](../Sources/TokenHUD/HUDSync.swift) | `entry`、`sync`、`stageAssets` | 构造 v2 契约，验证并复制运行时、包装脚本与手填 Key，更新 C 配置 |
| [statusline.mjs](../Sources/TokenHUD/mjs/statusline.mjs) | `renderEnvQuota`、`maybeSpawnIndependent` | 解析 Claude Code 输入、选择显示账号、渲染 C 缓存、按 TTL 启动 worker |
| [hud-runtime.mjs](../Sources/TokenHUD/mjs/hud-runtime.mjs) | `entryRevision`、`hudCachePath`、`attemptFresh` | 配置摘要、缓存路径校验、60 秒 TTL 和安全错误码 |
| [ref-usage-provider.mjs](../Sources/TokenHUD/mjs/ref-usage-provider.mjs) | `main`、`resolveInput`、`usageOnly` | 单账号查询生命周期、锁、认证快照、适配器调用、迟到响应防护及缓存发布 |
| [source-readers.mjs](../Sources/TokenHUD/mjs/source-readers.mjs) | `readReference`、`resolveCredential`、`accountIdentity` | 只读解析 A，校验来源归属与身份，按声明格式取凭证 |
| 供应商包装与适配器，例如 [GPT 包装脚本](../Sources/TokenHUD/providers/gpt/fetch.sh) | 环境变量输入、标准 JSON 输出 | 实现供应商请求和返回解析，不承担 B/C 生命周期管理 |

新增供应商优先通过类型声明和适配器扩展，不在导出器或通用 worker 中增加供应商 slug 分支。新增来源容器格式则属于来源读取模块的职责，需与 B 的只读解析语义核对。

## 3. 运行包与路径归属

以下是默认部署布局示意，尖括号表示账号 slug，不是固定文件名：

```text
~/.claude/
├── settings.json                   # env.ACCOUNT_ENVS 与 statusLine 接线
└── hud/
    ├── envs.json                   # C 的导出契约
    ├── statusline.mjs
    ├── hud-runtime.mjs
    ├── source-readers.mjs
    ├── ref-usage-provider.mjs
    ├── <provider-adapter>.mjs      # 导出复制的供应商适配器
    ├── providers/<slug>/fetch.sh
    ├── .<slug>-hud-auth.json       # 仅手填 Key，0600
    ├── .<slug>-hud-cache.json      # C 查询结果，0600
    ├── .<slug>-hud-cache.json.lock/# 单账号 worker 锁
    └── .git-cache.json             # 分支显示缓存，30 秒 TTL
```

C 默认从 `CLAUDE_CONFIG_DIR`（未设置时为 `~/.claude`）定位 Claude 配置；`TOKENHUD_HUD_DIR` 可覆盖 HUD 目录。导出条目的绝对路径必须与运行时目录一致，不承诺复制文件夹后所有绝对引用自动迁移。

B 使用自己的私有 runtime。历史 `usage-auth`／`usage-cache` 文件即使位于同一 HUD 父目录，也不属于 C v2 的输入。C worker 强制临时认证与临时缓存路径，不能让包装脚本的旧默认值意外读到 B 文件。

## 4. 导出配置契约

[HUDSync.swift](../Sources/TokenHUD/HUDSync.swift) 中的 `EnvsEntry`、`HUDQuery`、`HUDCredential` 定义导出模型。顶层 `_schemaVersion` 为 2；每个受 QuotaNest 管理的条目也有 `schemaVersion: 2`。第三方条目保留自己的版本，不因顶层版本而自动升级。

| 字段 | 语义 |
| --- | --- |
| 对象 key／slug | 稳定账号标识，不能使用可能重复的显示名代替 |
| `label`、`buckets` | 显示标签、已知用量桶的标题 |
| `managedBy` | 当前导出为 `quotanest`，用于识别应用管理范围 |
| `source` | `cache` 表示 C 自行查询缓存；`api` 表示仅 API、无额度查询，不启动 worker |
| `cache`、`fetch` | C 自有缓存绝对路径和复制后的包装脚本路径 |
| `reference` | A 的 source/path/recordId 及可选 providerId、collection、credentialProviderId、身份等证据 |
| `credential.formats` | Auth 格式字段映射；是元数据，不是解析出的秘密 |
| `credential.file` | 独立 Auth 账号的外部只读文件路径 |
| `credential.keyFile` | 手填 Key 的 C 自有导出快照路径 |
| `query.url` | 明确声明的用量地址，不能由模型接口地址猜测 |
| `query.headerTemplate`、`authHeaderTemplate` | API Key／Auth 请求头模板，`<key>` 为替换位 |
| `query.inheritHeaders` | 是否合并认证格式声明中的请求头字段；显式覆盖时关闭 |
| `query.keyField`、`quotaMode` | 适配器兼容快照字段及额度模式 |
| `query.authMode`、`quotaAuthModes`、`queryAuth` | 导出的认证声明与能力约束；引用账号的实际模式由来源记录决定 |

认证解析优先级是 `reference` → `credential.file` → `credential.keyFile`；不是失败后的回退链。选中的来源失败就报告错误，不尝试旧 Key 或别的账号。导入条目不在导出阶段解析 A，手填 Key 则在导出时写快照；清空时写空 Key 覆盖旧值。

`ACCOUNT_ENVS` 决定显示顺序。渲染器直接读 Claude 设置，只有多值键不存在才兼容 `ACCOUNT_ENV`；显式空列表表示不显示账号额度，不回退环境变量选择。

## 5. 显式导出的执行步骤

1. 根据账号启用状态、停用列表及 HUD 隐藏列表筛选账号，保持本地顺序。
2. 读取既有 Claude 设置与 C 条目，识别受 B 管理的旧条目及历史名称。非受管条目按原始 JSON 保留，包括未知嵌套字段、其他结构及第三方元数据；不通过 QuotaNest 的 Codable 模型重新解释。
3. 生成 v2 元数据，暂存所有 mjs 文件、所需包装脚本和手填 Key 内容。缺少四个核心运行时或已识别的包装脚本适配器依赖时提前失败。
4. 首次保留 Claude 设置备份，记录待覆盖资产和配置的旧内容，写入运行资产，再写 C 条目和 Claude 设置。
5. 成功后清除 B 内存及偏好存储中的待导出标记，UI 显示反馈；配置提交失败时保留待导出状态，执行当前实现的恢复逻辑并报告恢复结果。

当前实现有三个必须如实保留的边界：

- 已有 `statusLine.command` 会保留；仅缺失时补上 Node 命令。导出成功不自动证明已有自定义命令会执行本 HUD。
- 资产写入循环位于配置提交的 `do/catch` 之前。配置提交失败有资产／条目恢复逻辑，但资产写入中途失败并没有同等完整回滚；不能把整个导出描述成全局原子事务。权限设置使用尽力执行，也不等于已验证所有文件系统上的权限结果。
- 移除受管条目不等于垃圾回收全部历史脚本、缓存和 Key 文件；当前导出没有完整的孤立文件清理阶段。待导出标记持久化于 B 的偏好存储，重启后保留；它记录本地导出相关动作，不是自动扫描两端配置差异的检查器。

这些是当前实现边界，不改变“只有点击按钮才能写 C”的需求；本文不借文档任务修改运行代码。

## 6. 渲染与按需查询

[statusline.mjs](../Sources/TokenHUD/mjs/statusline.mjs) 每次启动读取 stdin 的工作目录、上下文、模型和原生 rate limits，建立显示注册表，再读取所选账号。

对于 v2 账号：

1. 用 slug 计算 C 专用缓存路径，计算导出条目的 `configuration` 摘要。
2. 缓存配置摘要不一致时忽略旧缓存；不读取来源整文件 mtime。
3. 按最近成功时间判定显示是否陈旧，按最近尝试时间判定是否启动查询。这两个时间不可混为一谈，失败不能刷新“最近成功”；渲染器与 worker 共用时间校验，非有限数或未来时间不视为新鲜，避免系统时钟回拨造成长期停查。
4. 无缓存或尝试已过 60 秒，启动 `process.execPath` 指向的 detached worker，传 slug，断开标准流并 `unref()`。
5. 立即输出当前可用内容。旧额度带 `*`；无额度时显示加载或安全错误。当前渲染在有旧额度时通常优先显示额度与星号，并非所有错误都会同时展开显示；`auth` 会直接显示“需登录”。

C 不在每次渲染重新读取 A；来源变化在下一次允许的 worker 查询中检测。因此不能承诺 A 切换账号后零延迟清除屏幕旧值。

## 7. Worker 生命周期与并发

[ref-usage-provider.mjs](../Sources/TokenHUD/mjs/ref-usage-provider.mjs) 的 `main()` 流程为：

1. 验证 slug，读取 v2 条目；仅 API 条目直接返回。
2. 在稳定账号锁目录中创建 PID + UUID 唯一声明文件，以 choosing 状态和递增票号协调竞争；发现未完成选票或更早竞争者时退出。只回收确认死亡 PID 的声明文件，释放也只删除本进程此次声明，不删除共享目录。旧版本 owner 存活时保守等待；损坏旧 owner 保留 60 秒后可恢复。该协议针对本地文件系统，PID 复用时保守等待。
3. 获取锁后再次检查缓存 TTL，避免并发渲染重复请求。
4. 解析来源与认证，生成请求快照、身份绑定和请求版本。解析失败时发布安全错误，不携带旧身份用量。
5. 写入尝试时间及 `querying/stale` 状态；仅保留配置与身份绑定均一致的旧成功值。
6. 校验缓存路径精确一致且 fetch 位于 C 的 providers 目录。创建 0700 临时目录，写 0600 认证快照及可选旧用量快照。
7. 用 `/bin/zsh` 执行包装脚本，21 秒超时、最大输出 2MB。清除调试环境开关，避免适配器落原始响应。
8. 返回后重新核对条目摘要并重新读取认证；配置已经变化则不发布，认证快照版本变化则丢弃响应。
9. 解析标准 JSON，过滤用量字段并发布 C 缓存。普通请求失败只能继承绑定一致的旧用量与成功时间。
10. 在正常 `finally` 路径清理临时目录与自己的锁声明；空锁目录保留。进程被强杀时不保证 finally 执行，后续可回收死亡进程的声明；当前没有独立临时目录巡检清理器。

传给包装脚本的关键环境变量：

| 变量 | 值与作用 |
| --- | --- |
| `TOKENHUD_NODE` | 当前 Node 可执行路径 |
| `TOKENHUD_HUD_DIR` | C 的运行目录，用于定位复制后的适配器 |
| `TOKENHUD_AUTH_FILE`／`USAGE_AUTH_FILE` | 本次临时认证快照，覆盖旧默认来源 |
| `TOKENHUD_CACHE_FILE`／`USAGE_CACHE_FILE` | 本次临时缓存，不能指向 B 缓存 |
| `TOKENHUD_STDOUT_ONLY=1` | 返回标准 JSON，不自行写正式共享缓存 |
| `TOKENHUD_QUERY_URL`／`TOKENHUD_QUOTA_MODE` | 本次明确的用量地址与模式 |

## 8. 来源读取与身份防护

[source-readers.mjs](../Sources/TokenHUD/mjs/source-readers.mjs) 支持 Magpie 的原生登录、插件授权、provider Key 槽，9router 与 cc-switch 的指定 SQLite 记录，以及 CPAMP 授权 JSON。支持某来源不代表支持该来源的全部认证类型；无内联授权、依赖 Keychain、加密数据库或需要续期的情况不能假装可读。

JSON 按明确路径与记录定位；SQLite 优先使用 `node:sqlite` 只读连接，并设置 `query_only`，不支持时回退只读 sqlite3 CLI。路径字段映射支持点路径、JSON Pointer 和嵌套 JSON 字符串。读取有大小／超时约束，不扫描其他记录猜测可用凭证。

三个运行时摘要分别解决不同问题：

| 摘要 | 构成 | 用途 |
| --- | --- | --- |
| `configuration` | 整个导出条目的规范化哈希 | 配置变化后拒绝旧缓存和迟到写入 |
| `binding` | 配置摘要 + 账号身份 + 有效请求的 chatgpt-account-id；无可用 Auth 身份时回退凭证摘要 | 判断旧成功用量是否属于当前绑定 |
| 内存 `revision` | 本次解析后的认证请求快照摘要 | 请求前后凭证或请求内容变化时丢弃回包 |

来源引用可携带 `identityAccount`，读取时校验。身份摘要的规范序列化需与 Swift 一致，包括 Foundation 对斜杠的转义。令牌正常轮换与账号变化不应混淆；但缺少稳定身份证据时，当前实现会保守地把凭证变化当作不同绑定。

来源模块还导出 `sourceRevision`／`bindingDigest` 辅助函数；worker 当前使用的是自身 `resolveInput` 中的摘要，不能误写成 worker 直接用来源整记录摘要判缓存失效。

## 9. 缓存与错误契约

正式缓存通过同目录临时文件写入后 rename 发布，避免读到半截 JSON。缓存内容包含：

- 元数据：`schemaVersion`、`configuration`、`binding`、`lastAttemptAt`、`ttlMs`。
- 成功状态：`generatedAt`、`stale`、`error`；查询中可带 `querying`。
- 用量：`five_hour`、`seven_day`、`monthly`、`windows`；保留有限数值及经过清理的 label/period/unit。重置时间按秒解释，缺失不制造。

缓存不保存原始响应、完整来源对象或凭证。字符串去控制字符、限长并替换已知秘密。错误按白名单映射，未知错误统一为查询失败，不把供应商诊断原文打印到终端。

来源缺失／身份不匹配会清除旧用量；同绑定网络或解析失败可以保留旧成功时间与旧用量并标记陈旧。配置在 worker 执行中变更时直接弃写，交由后续渲染触发新查询。无论何种失败，均无“向 B 取缓存”的降级路径。

## 10. 兼容边界与验证入口

v2 条目覆盖同名旧内置注册项。旧动态导出条目提示重新写入；但没有 v2 覆盖的旧内置 GLM/GPT 等分支仍可使用历史 usage 路径。`Claude-Max` 保留读取 Claude Code stdin 的原生 rate limits 路径。故不能把当前整个文件中的每条历史路径都称为已完成 v2 解耦；新导出账号必须遵守 v2 契约。

相关回归入口：

| 文件 | 覆盖职责 |
| --- | --- |
| [HUDSyncTests.swift](../Tests/TokenHUDTests/HUDSyncTests.swift) | 导出元数据、来源引用、脚本、设置与失败处理 |
| [DataEngineTests.swift](../Tests/TokenHUDTests/DataEngineTests.swift) | B 本地操作与显式导出的边界 |
| [HUDAccountIsolationTests.swift](../Tests/TokenHUDTests/HUDAccountIsolationTests.swift) | 多账号身份与显示隔离 |
| [test-hud-source-readers.mjs](../scripts/test-hud-source-readers.mjs) | 来源格式、只读 SQLite、身份与凭证解析 |
| [test-referenced-source-cache.mjs](../scripts/test-referenced-source-cache.mjs) | 独立 worker、TTL、来源变化、并发与缓存隔离 |
| [test-hud-provider-integration.mjs](../scripts/test-hud-provider-integration.mjs) | 包装脚本及实际适配器的离线输入输出 |
| [test-statusline-colors.mjs](../scripts/test-statusline-colors.mjs) | 状态栏渲染回归 |

修改导出契约时同时检查 Swift 写端、Node 读端和配置摘要；修改认证映射时核对 B/C 解析的一致性，但不要引入互相调用。离线 fixture 通过只能证明本地协议与隔离行为，不能证明真实订阅联通、全部来源格式或供应商窗口机制。本次文档改写仅核对源码和文档，不重复声称新的在线或实机测试结果。
