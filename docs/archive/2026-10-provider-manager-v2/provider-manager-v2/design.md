# TokenHUD 供应商管理 v2 — 设计决策

> 本文是本轮验收主文档，记录主线程已定方案。其他旧草稿原样保留，不覆盖，也不作为本轮交付入口。事实缺项标「待验证」，不标已通过；以 QA 与主线程验收结果更新完成状态。

## 0. 范围与进度

**用户在 `daa94bf` 之后的不满**：旧版只换列表排布，编辑路径 / 主题 / 功能入口三者不一致。

**当前交付边界**

| 层 | 内容 | 状态 |
|---|---|---|
| 设计 | 本文 + 可交互 HTML 原型 + QA 验收 | **完成**（2026-10-29，见第 7 节） |
| 原生 Swift 落地 | App 内实际实现 | **0%，未开始** |

设计层完成：Git 留档、调研、方案与原型 QA 验收均已完成（验收结论见第 7 节）。原生层：Swift 实现尚未开始，未重新编译打包。

- 原型 ≠ 产品。HTML 走通只证明交互设计成立。
- 不称「用户已选定 A」。A 是主线程建议，非用户决定。
- 本轮不改 App、不重新编译打包、不调用外网。HTML 使用内存演示数据，每个原型刷新后恢复初始演示数据，原生 App 没有改变。

## 1. 三套方案

三套覆盖同一能力集：总览、新增、API Key 编辑、授权登录 / 本机来源、导入预览与结果、自动触发。

| | A 工作台（推荐） | B 运行台 | C 设置中心 |
|---|---|---|---|
| 外观 | 暖白 / 墨绿 `--canvas:#F5F6F2` | 深色 / 灰蓝 `--canvas:#151D28` | 冷白 / 靛蓝 |
| 导航 | 左侧任务导航：额度总览 / 供应商账号 / 自动触发 | 顶部导航 | 左侧账号列表 + 搜索分组 |
| 主区 | 整页分区编辑 | 额度数据表 + 可收起检查器；整宽编辑 | 右侧 额度 / 配置 / 自动触发 tab |
| 编辑 | 分区整页 | 检查器展宽 | 就地编辑 + 草稿 |
| 触发 | 按时刻排计划 | 按时刻排计划 | 当前账号的自动触发 tab |
| 导入 | 同层级大面板 | 带逐项结果与重试的任务队列 | 宽 sheet |
| 适合 | 看额度与安排触发并重 | 多账号高密度 | 少账号、稳定配置 |

**三套不是 App 内长期并存的冗余 UI**，仅用于方案对比。原生落地优先 A（主线程建议，非用户已选）。

三方案的主题 token 用于比较；A / B / C 目前各自仅展示一种特定外观，不代表 App 已支持深浅色。未来原生落地以系统字体、语义 surface 与标准控件为基线，可定制主题背景和图表 accent，不硬改系统原生按钮 tint 来覆盖用户 accent。原生外观随系统切换、高对比与 reduced-motion 支持在 P3 单独验收；本轮不新增暗色开关。

原型入口位于 `docs/provider-manager-v2/prototypes/`：

| 方案 | 本地文件 |
|---|---|
| A | `workbench.html` |
| B | `operations.html` |
| C | `settings.html` |

文件产出与验收状态见第 7 节的带时间记录，不以文件大小判断完成度。

`index.html` 提供 3 个整页对比入口与 inline iframe 预览；窄视口降级为纯链接。页面标注演示数据、不访问 API。不装依赖、不用 CDN。

> 入口不依赖未验收的查询参数深链；各方案内的操作路径由浏览器验收单独确认。

## 2. 共同域模型

四层必须分清，不可互相替代：

1. **供应商模板**（`providers/<slug>/manifest.json`）
2. **账号实例**（同一模板可多实例）
3. **额度适配**（queryUrl / queryAuth / 解析脚本）
4. **模型调用能力**（refreshUrl / refreshProtocol / testModel）

**身份 = API Key 或 授权登录**。本机 CLI 登录只是**登录来源**，不是第三种身份。`queryAuth` 是传输 / 存储方式（bearer / header），不是身份。

**调用协议 ≠ 额度接口适配**。OpenAI / Anthropic 协议描述「怎么调用模型」，与「怎么查额度」无关。

已确认的当前 TokenHUD 适配能力（据 `Sources/TokenHUD/providers/*/manifest.json`）：以下仅描述本应用已提供的适配，不据此推断供应商本身是否支持模型调用。

| 供应商 | 额度查询适配 | 模型调用适配 | 依据与凭证来源 |
|---|---|---|---|
| GLM | 已提供 | 已提供 | `refreshUrl` + `refreshProtocol: anthropic` |
| Ollama | 已提供 | 已提供 | `refreshUrl` + `anthropic` |
| OC-Go | 已提供 | 已提供 | `refreshUrl` + `openai` |
| GPT | 已提供 | 当前 TokenHUD 适配未提供调用 | 有 `queryUrl`，无 `refreshUrl`；仅使用本机 Codex 登录来源 |
| Cline | 已提供 | 当前 TokenHUD 适配未提供调用 | 有 `queryUrl`，无 `refreshUrl`；使用 Cline API Key |

红线：

- 不假造 OAuth 登录按钮。
- 不复制、不写回 CLI 的 `refresh_token`。
- 不拿通用 one-api 口径套所有中转余额。
- 无查询适配的账号仍可管理调用，但显示「未适配」，**不显示绿色额度正常**。

**buckets JSON 契约**（据 `Models.swift:136-148`）：`generatedAt`(ms) / `five_hour` / `seven_day` / `monthly` / `error` / `stale`。沿用 `generatedAt`，不改数据契约。

## 3. 动作语义

| 动作 | 语义 | 必须明示 |
|---|---|---|
| 查询额度 | 不消费模型 token | — |
| 检查本机凭证 | 只读文件，判断存在 / 结构 | 不声称「有效」 |
| 发送一次测试调用 | 会消费额度 | 不保证重置 5h 窗口，不承诺提前重置 |
| 定时触发 | 仅「有调用能力」账号可开 | 本机时区；App 需运行；睡眠漏过不补发；**保存本身不调用** |

**自动查询额度与自动触发模型调用是两个独立开关，无总监控开关**：

- `autoQueryEnabled`：自动查询额度。GPT / Cline 同样支持自动额度查询，仅有此开关。
- `autoTriggerEnabled`：自动触发模型调用。仅有调用能力的账号可开启并配置定时；generic 账号只有调用可启定时。
- 关闭自动查询不影响手动查询、手动调用，也不影响已启用的定时触发。
- 开启自动查询不自动开启消费调用；保存本身不发起任何请求。

**结果分离**：调用结果与额度查询结果分开呈现，不用一次 toast 假装两件事都成功。

**状态分维度建模，可独立并存**，不压成单一 enum：

| 维度 | 状态 |
|---|---|
| 自动查询 | 开 / 关（`autoQueryEnabled`） |
| 自动触发 | 开 / 关（`autoTriggerEnabled`，仅调用能力账号） |
| 查询 | 尚未查询 / 进行中 / 成功 / 凭证问题（缺凭证或需登录）/ 网络失败 |
| 额度 | 已用 / 耗尽 / 未知；另外记录是否过期 |

例如，账号可同时处于「自动查询关闭」「最近查询失败」「缓存额度耗尽且过期」。界面最多突出一个主状态，并用辅助说明保留其余维度；UI 文案、错误码映射及组合状态一并纳入验收。

## 4. 统一编辑

- 内置模板 endpoint 只读；凭证按身份（API Key / 授权登录）分别展示。
- 字段分组：基本账号 / 凭证来源 / 额度查询 / 模型调用与定时；高级 header 收起。
- 草稿与持久化分离：切 tab 不丢；取消 / Esc / 切账号 / 关闭前 dirty 确认。
- 校验就地：名称、key、URL、HH:MM；**总错误永远可见**。
- GPT 不要求 API key；Cline 无定时开关。
- 固定保存 / 取消栏，内容区独立滚动。
- 新增先「模板卡 / 目录」，再进**同一个 editor**——不是旧 Picker。

## 5. 导入契约

源选择 → 扫描 → 预览 → 确认 → 逐项结果。

- 预览分四类：可新增 / 已存在 / 不支持 / 额度未适配。
- 部分失败可重试，但**不再导已成功项**。
- 默认跳过重复，**不自动覆盖 key**。
- 可能重名 ≠ 同一身份：不按 `name` 把账号合并。
- 源只读：不改对方数据库、不改 CLI auth。
- 真实 scan 异步，带超时、可取消；**错误不可等于空结果**。

> 待验证：当前原型内所有扫描均为内存演示；真实 importer 未修。

## 6. 原生落地顺序（本轮只设计，不执行）

| 阶段 | 内容 | 验收门槛 |
|---|---|---|
| **P0** | 修 / 回归凭证契约、Importer 路径隔离、删除确认与真实刷新结果；DataEngine 拆开自动查询调度与触发调度；先完成导入隔离修复与验证，再跑新增 / 导入回归 | 满足下述 P0 具体标准再前进 |
| **P1** | 轻量 theme token + 统一窗口与 editor（**不新增架构层 / 工厂**） | 编辑路径单一 |
| **P2** | 整合 A 的总览 / 编辑 / 新增 / 导入状态与能力显隐；落地 `autoQueryEnabled` / `autoTriggerEnabled` 双开关 UI（GPT / Cline 仅自动查询，generic 仅调用可启定时） | 能力矩阵生效 |
| **P3** | 测试 + App 截图 + 全链路；另验随系统切换外观、高对比、reduced-motion 与原生窗口交互，再打包 | 全链路与原生外观验收通过 |

### P0 具体验收标准（本轮仅定义，不执行）

- **凭证字段兼容**：Cline 读取既有 `apiKey` 后，编辑保存能更新同一字段；由模板创建的账号实例写入后，对应 provider 能读取凭证；保存保留旧 auth 中的未知字段。遵循插件架构，使用 manifest 可选映射或既有通用机制，不允许在 `ProviderConfigStore` 中加入 `if slug == "cline"` 特判。
- **导入路径隔离优先**：`ProviderImporter` 所有分支均以注入的 `hudDir` 为写入目标。使用临时 `HOME` 的验证不得访问真实用户的 `~/.claude`；凭证测试必须断言实际落盘路径，并确认写入限定在测试目录。先修复并验证此项，再运行新增 / 导入回归，避免污染用户目录。
- **真实刷新反馈**：`forceRefresh` 返回或传递实际结果，界面按结果反馈。关闭自动查询的账号仍可手动查询（或明确禁用该操作并说明原因）；不得静默 `guard` 返回后仍报告成功。后台调度失败须保留可查询的结果；模型调用与额度查询的结果继续分开呈现。
- **调度拆分与旧数据迁移**：`DataEngine` 拆开自动查询调度与自动触发调度，分别由 `autoQueryEnabled` / `autoTriggerEnabled` 控制。迁移旧 `disabledSlugs` 时两开关默认 **off**，不得静默开启模型调用；两开关独立保存，保存本身不发起任何请求。

以上标准约束现有机制的行为与回归，不新增架构层。

涉及路径（清单，不预设全量重写）：

```
Sources/TokenHUD/Models.swift
Sources/TokenHUD/ProviderConfigStore.swift
Sources/TokenHUD/ProviderImporter.swift
Sources/TokenHUD/PluginGenerator.swift
Sources/TokenHUD/DataEngine.swift
Sources/TokenHUD/RefreshTrigger.swift
Sources/TokenHUD/ui/ProviderManager.swift
Sources/TokenHUD/ui/ProviderLayouts.swift
Sources/TokenHUD/ui/EditForm.swift
Sources/TokenHUD/ui/ImportSheet.swift
Sources/TokenHUD/ui/StatusItemController.swift
Sources/TokenHUD/providers/*
```

**插件架构不可变**：加供应商不改主框架。能力可由 manifest 声明或通用推导，**不允许框架内 slug switch**。

## 7. 验收矩阵

三套各至少覆盖 7 项：总览 / API Key 编辑 / 本机登录 / 新增 / 导入预览 / 导入部分失败 / 触发配置。

| 类别 | 项 |
|---|---|
| 视口 | 1100×760 与 900×640；字号 / 对比 / focus 环 / 按钮反馈 |
| 路径 | 搜索 → 选账号 → 改名 → 保存 → 重开 |
| 校验 | 无效 HH:MM 保存被拒 |
| 草稿 | 取消时 dirty 留 / 弃 |
| 能力 | GPT 无可开触发；通用查询未适配 |
| 导入 | 重复跳过；部分失败重试 |
| 危险操作 | 删除需确认 |

**证据分级**：截图只证明视觉；浏览器路径只证明原型行为。Swift 构建、原生键盘、窗口拖动 / 位置 / 单例必须在原生实现后单独验证，**不得拿 HTML 通过冒充**。

### 验收记录

记录按时间保留快照，文件存在仅表示已产出，不等于行为或视觉验收通过。

**最终验收（QA 独立浏览器会话，2026-10-29）**：三套全部 PASS。冻结 hash 由 QA 报告 `acceptance.md` 给出，与收尾时本仓实测一致。范围限定演示行为（双视口布局、双开关独立、能力 gate、URL/HH:MM 校验、脏态、导入部分失败重试、删除确认、0 外网请求）；未验真机 App、Safari/Firefox、深色模式视觉、真实导入数据形状（见 acceptance.md 第 7 节）。

| 项 | 方案 | 结果 | 证据 | 快照时间 |
|---|---|---|---|---|
| 原型文件产出核实 | A | 文件存在（后续行为 / 视觉验收见下方 QA 行） | `prototypes/workbench.html`，标题「TokenHUD 供应商管理 · 工作台（交互原型）」 | 2026-10-29 14:54:02 CST (UTC+08:00) |
| 原型文件产出核实 | B | 文件存在（后续行为 / 视觉验收见下方 QA 行） | `prototypes/operations.html`，标题「TokenHUD · 运行台（交互原型 B · 演示数据）」 | 2026-10-29 14:54:02 CST (UTC+08:00) |
| 原型文件产出核实 | C | 文件存在（后续行为 / 视觉验收见下方 QA 行） | `prototypes/settings.html`，标题「TokenHUD · 设置中心（交互原型）」 | 2026-10-29 14:54:02 CST (UTC+08:00) |
| 独立浏览器 QA（冻结 hash 核对） | A | **PASS** | `6ae6a2f86dba3aaf45f21d8d18970cdef60b0dde0be0bf881156b9598bba9729`；acceptance.md §3-A（URL 组经返工复跑） | 2026-10-29 16:23:00 CST (UTC+08:00) |
| 独立浏览器 QA（冻结 hash 核对） | B | **PASS** | `fb7ac2782a8466b27e88a95aede15ce8ead860eca58bff40c21021e51c9b2ddc`；acceptance.md §3-B | 2026-10-29 16:23:00 CST (UTC+08:00) |
| 独立浏览器 QA（冻结 hash 核对） | C | **PASS** | `52a79ee33251056e7fab2d777b5f398d4177bac9321bb525fa2d80f2a79fac58`；acceptance.md §3-C | 2026-10-29 16:23:00 CST (UTC+08:00) |
| 双视口与完整交互路径 | A / B / C | **PASS**（1100×760 与 900×640） | acceptance.md §3 各套视口行 + §4 截图 | 2026-10-29 16:23:00 CST (UTC+08:00) |
| 主线程方案验收 | A / B / C | **通过**；推荐 A 为原生落地首选 | 截图逐张 Read + QA 报告已核；hash 同上三行（A `6ae6a2f8` / B `fb7ac278` / C `52a79ee3`） | 2026-10-29 16:24:03 CST (UTC+08:00) |

## 8. 参考（仅已知事实）

- **cc-switch**：`FullScreenPanel` + `ProviderForm` 同壳承担添加与编辑（`src/components/providers/{AddProviderDialog,EditProviderDialog}.tsx`）。
- **9router**：语义化 CSS tokens（`globals.css`），`queued` / `testing` 结果态。
- **CPAMP**：`ProviderEditDrawer`、`credentialStatus`、部分导入结果。
