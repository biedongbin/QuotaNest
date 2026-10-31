# gpt-codex 需求｜S3 供应商包 v0.2

日期：2026-10-30。证据分级：**A＝本日一次官方只读响应**；**B＝代码现状**（`Sources/TokenHUD/mjs/gpt-usage-provider.mjs`、`Sources/TokenHUD/providers/gpt/`）；离线 fixture 用于行为回归，不冒充接口实测。目标要求引用 [04](../../04-global-requirements.md)／[05](../../05-global-technical.md)。

## 1. 账号与授权

- 账号类型：ChatGPT 订阅账号（Codex 权益），凭证来源为**只读本机 Codex CLI 登录**——`${CODEX_HOME:-~/.codex}/auth.json`（B）。
- 只读边界（B，符合 FR-02.4）：App 不写回 auth.json、不擅自用 refresh_token 刷新——Codex CLI 管 token 轮换，双写者触发 reuse 作废家族。凭证过期恢复＝用户在 Codex CLI 重新 `codex login`。
- 有效凭证判定（B）：`auth_mode==="chatgpt"` 且 `tokens.access_token` 存在；`tokens.account_id` 作为账号身份字段。
- 多实例：受来源限制——本机一份 auth.json 对应一个登录账号；多实例须指向不同 CODEX_HOME（auth 指针 `codexAuthFile` 可覆盖，B）。同机多账号切换语义**待核实**。
- 身份与调用凭证（FR-02.6）：`account_id` 为本地身份字段，查询与调用是否可共用此来源由 provider 声明——调用路径当前**未接入**（见能力矩阵）。

## 2. 额度语义

- 官方端点（A、B）：`GET https://chatgpt.com/backend-api/wham/usage`，Bearer access_token＋有账号身份时的 `chatgpt-account-id` 头。
- 主额度容器（B）：优先 `rate_limit`，兼容 `rate_limits`／`rate_limits_by_limit_id.codex`；空或无有效百分比的容器不遮挡后续有效兼容对象。`primary_window|primary` 与 `secondary_window|secondary` 是主次角色，**不能据此推断 5 小时或 7 天**。
- 周期（A、B）：使用窗口的明确字段 `limit_window_seconds`。`18000`＝5 小时，`604800`＝7 天；不通过 `plan_type`、主次位置或剩余重置倒计时猜测周期。
- 已知周期（B）：动态窗口分别用“5小时”／“本周”短标签，`period` 明确“5小时”／“7天”。“本周”仅为现有 UI 的简写，不能据此宣称周一自然周重置或滚动机制；重置时刻始终用官方值。
- 其他明确时长（B）：如 `86400` 显示“24小时”；保留动态窗口，不投影为虚假的 5h、周或月额度。缺失、非法、非正时长用“主额度窗口”／“次额度窗口”及“周期未知”。
- 百分比（B）：`used_percent`｜`percent_used`，口径为已用百分比；有效数值与数值字符串保留真实 0，缺失／null／空串／NaN／布尔值不伪造 0%。沿用 0—100 边界与 0.1 精度显示。
- 附加限额（B，兼容形态仅离线回归）：`additional_rate_limits` 的具名有效窗口与 `rate_limits_by_limit_id` 的其他模型限制分别保留，标签带身份；同一 identity 的容器别名不重复输出，不因相同百分比或周期合并不同模型限制。
- 旧 HUD 投影（B）：仅明确且唯一的**主额度** 5h／7 天窗口写入 `five_hour`／`seven_day`。附加模型限制不覆盖主桶，同一主额度有多个同周期约束时动态窗口保留角色，旧单一桶留空以避免任取一个冒充完整额度。
- `monthly` 仍为空；不造缺失或 null 窗口卡（FR-03.5）。

### 2026-10-30 实测边界（A）

一次有界官方 GET 返回 HTTP 200、后端 `plan_type="prolite"`；`primary_window` 已用 18%、`limit_window_seconds=604800`、`reset_at=1793776498`、`reset_after_seconds=426097`；未返回有效次窗口。这只证明**该次响应的主额度是一个 7 天窗口**，不证明任何套餐永久只有一个窗口，也不把后端字符串改写为商业套餐名。

原实现固定 `primary→five_hour`，导致“5h、4d22h 后重置”；实际是周额度被错标。修复后成功查询重建窗口并清除错误旧桶。若查询失败，无显式周期的历史快照不能反推修正，应保留并标旧值，等待成功响应。

## 3. 能力矩阵

| 能力 | 结论 | 证据 |
| --- | --- | --- |
| 额度查询 | 支持：wham/usage 官方端点 | A、B |
| 模型调用 | **未接入**：manifest 无 refreshUrl／refreshProtocol（B）——订阅权益是否可经 API 直接调用待取证，不从额度兼容推断调用兼容 | 缺证据 |
| 自动查询 | 通用 FR-05；intervalSec=60（B，同 glm 待 S5 取舍） | B |
| 定时调用 | 依赖调用能力，当前不可用；计划入口显示“未接入”而非假按钮（FR-09.4） | — |

## 4. UI 要求（引 FR）

- FR-02.1／FR-02.4：来源标“只读 CLI（Codex）”；不提供假“登录”按钮（FR-02.5）。
- FR-02.7：access_token 由 Codex CLI 轮换＝同账号 token 轮换，可保留旧快照标“需用新凭证验证”。
- FR-03.2：`used_percent` 原义已用展示，动态窗口显示真实周期与重置时间，不补造 5h 模块。
- FR-08.5：主额度的动态窗口与旧 HUD 投影一致；当前 7 天主窗口必须进入周桶。旧 HUD 仅能表达三个固定桶，未知周期及附加模型的完整窗口展示以动态 UI 为准，不能宣称旧 HUD 已支持这些新形态。
- 调用能力未接入期间：测试调用按钮置灰＋“本 App 未接入”原因（FR-09.4），不静默隐藏。

## 5. 错误恢复

| 错误 | 判定（B） | 恢复 |
| --- | --- | --- |
| 凭证失效 | HTTP 401／403 | 提示 `codex login`（FR-09.6 入口） |
| 无登录 | auth.json 缺失／auth_mode 非 chatgpt／无 access_token | no-auth，同上 |
| 限频 | HTTP 429 | ratelimit；交由通用引擎退避 |
| 网络 | curl 失败／其他非 200 | network；同账号旧桶或动态窗口保留 |
| 解析 | 非 JSON／无有效窗口字段 | parse；保旧值，不伪造 0% |
| 账号切换 | 旧缓存 `account_id` 与当前不一致 | 不沿用旧账号额度（B writeFailure 同账号判定）——身份变化隔离（FR-02.7） |

失败只更新 `lastAttemptAt` 并标 `stale`，不推进 `generatedAt`。旧缓存没有周期字段时不按新规则猜测改写；成功响应完整替换其投影，无需新增缓存版本。
