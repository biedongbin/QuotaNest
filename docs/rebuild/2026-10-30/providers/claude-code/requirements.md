# claude-code 需求｜S3 供应商包 v0.1

日期：2026-10-30。证据分级：**B＝代码现状**（`Sources/TokenHUD/mjs/statusline.mjs`）。本包为**本机数据来源包**，非官方余额接口（README 边界：不冒充官方余额接口）。目标要求引用 [04](../../04-global-requirements.md)／[05](../../05-global-technical.md)。

## 1. 账号与授权

- 来源类型：Claude Code statusline stdin 数据——Claude Code 进程每次渲染 statusline 时经 stdin 推送的 `rate_limits`（B：`stdin?.rate_limits`，含 `five_hour`／`seven_day` 两桶）。
- **无独立凭证、无网络请求**：数据由 Claude Code 自官方会话取得后推送，App 侧零凭证零调用。这不是一种新的授权方式，也不是 App 主动查询官方接口。
- 账号身份：绑定本机当前 Claude Code 登录；登录身份字段（如账号邮箱/ID）stdin 是否携带**待核实**（B 脚本未读此类字段）。无身份字段时快照关联按"本机 claude-code 来源"单实例处理。
- 多实例：默认单实例（本机一份登录）；多实例不可用属"服务能力不支持"，不以重复添加造多账号。
- 只读边界：App 不写 Claude Code 配置、不改活动账号（01 第 1 节：不是账号切换器）。

## 2. 额度语义

- 数据形状（B）：`rate_limits.five_hour` 与 `rate_limits.seven_day`，各含 `used_percentage`（已用百分数）与 `resets_at`（epoch 秒，B formatResetTime 按秒消费）——与官方 Claude 订阅 5h／周窗口对应。
- 数据更新时机：**仅 Claude Code 渲染 statusline 时推送**（会话活动时）；无会话活动则无新数据——快照时效按此现实，stale 阈值不适用全局默认 2×间隔，须按"最近一次 stdin 推送"表达（待 S2/05 精化，见 technical 第 4 节）。
- 官方语义边界：stdin `rate_limits` 是 Claude Code 暴露的官方限额快照，但**非 App 主动查询的官方余额接口**；展示须标来源"本机 Claude Code"（FR-03.1 来源语义），不与他包官方查询混排同一口径表述。
- 无月桶（B）；缺失桶不展示，不造空（FR-03.5）。

## 3. 能力矩阵

| 能力 | 结论 | 证据 |
| --- | --- | --- |
| 额度展示 | 支持：stdin rate_limits 被动接收 | B |
| 主动额度查询 | **不支持**：无官方查询端点接入；手动"查询"按钮对来源无意义，显示"本机来源随 Claude Code 会话更新"（FR-09.4） | B |
| 模型调用 | **不适用**：调用走 Claude Code 本身，App 不代发（不冒充第三种授权）；generic-openai-anthropic 包另行覆盖协议调用需求 | — |
| 自动查询 | 不适用（无查询动作）；数据到达即更新快照 | — |
| 定时调用 | 不适用 | — |

## 4. UI 要求（引 FR）

- FR-03.1／FR-08.5：展示标"来源：本机 Claude Code"；菜单栏／悬浮窗／HUD 与管理窗同数据。
- FR-09.4：无查询按钮或按钮态为"本机来源，无主动查询"——明确"不支持"而非静默禁用。
- FR-02.4：来源只读说明；无凭证配置区（避免误导用户以为要填 key）。
- FR-09.2：快照时间＝最近 stdin 推送时间；不显示"最近成功查询"误导语义。
- NFR-01：`used_percentage` 原义已用；缺失不为 0%。

## 5. 错误恢复

| 状态 | 判定 | 处置 |
| --- | --- | --- |
| 无数据 | 从未收到 stdin 推送 | unknown，提示"启动 Claude Code 会话后自动获得数据" |
| 过期 | 长时间无会话活动 | stale 标注＋数据时间；不伪造新值 |
| 身份切换 | 本机 Claude Code 换登录（待核实 stdin 是否可判） | 按换身份处理：不沿用旧账号值（FR-02.7） |

无网络错误类别（不发请求）；诊断按本机来源路径记录。
