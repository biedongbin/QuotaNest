# gpt-codex 需求｜S3 供应商包 v0.1

日期：2026-10-30。证据分级：**B＝代码现状**（`Sources/TokenHUD/mjs/gpt-usage-provider.mjs`、`Sources/TokenHUD/providers/gpt/`）。接口无本会话实测样本。目标要求引用 [04](../../04-global-requirements.md)／[05](../../05-global-technical.md)。

## 1. 账号与授权

- 账号类型：ChatGPT 订阅账号（Codex 权益），凭证来源为**只读本机 Codex CLI 登录**——`${CODEX_HOME:-~/.codex}/auth.json`（B）。
- 只读边界（B，符合 FR-02.4）：App 不写回 auth.json、不擅自用 refresh_token 刷新——Codex CLI 管 token 轮换，双写者触发 reuse 作废家族。凭证过期恢复＝用户在 Codex CLI 重新 `codex login`。
- 有效凭证判定（B）：`auth_mode==="chatgpt"` 且 `tokens.access_token` 存在；`tokens.account_id` 作为账号身份字段。
- 多实例：受来源限制——本机一份 auth.json 对应一个登录账号；多实例须指向不同 CODEX_HOME（auth 指针 `codexAuthFile` 可覆盖，B）。同机多账号切换语义**待核实**。
- 身份与调用凭证（FR-02.6）：`account_id` 为本地身份字段，查询与调用是否可共用此来源由 provider 声明——调用路径当前**未接入**（见能力矩阵）。

## 2. 额度语义

- 官方端点（B）：`GET https://chatgpt.com/backend-api/wham/usage`，Bearer access_token＋`chatgpt-account-id` 头。
- 窗口（B 解析兼容集，源自 9router codex.js MIT）：`rate_limit` 为主，兼容 `rate_limits`／`rate_limits_by_limit_id.codex`；`primary(_window)`→5h、`secondary(_window)`→周。
- 百分比：`used_percent`｜`percent_used`（已用口径，缺失／非法→null 不伪造 0%，B 符合 NFR-01）。
- 重置：`reset_at|resets_at|resetAt`（秒/毫秒按 `<1e12` 判定）＋`reset_after_seconds` 相对秒兜底（B）。
- 无月桶（B：`monthly: null`）；不造空窗口（FR-03.5）。

## 3. 能力矩阵

| 能力 | 结论 | 证据 |
| --- | --- | --- |
| 额度查询 | 支持：wham/usage 官方端点 | B |
| 模型调用 | **未接入**：manifest 无 refreshUrl／refreshProtocol（B）——订阅权益是否可经 API 直接调用待 S3/S5 取证，不从额度兼容推断调用兼容（04 共同判定规则） | 缺证据 |
| 自动查询 | 通用 FR-05；intervalSec=60（B，同 glm 待 S5 取舍） | B |
| 定时调用 | 依赖调用能力，当前不可用；计划入口显示"未接入"而非假按钮（FR-09.4） | — |

## 4. UI 要求（引 FR）

- FR-02.1／FR-02.4：来源标"只读 CLI（Codex）"；不提供假"登录"按钮（FR-02.5）。
- FR-02.7：access_token 由 Codex CLI 轮换＝同账号 token 轮换，可保留旧快照标"需用新凭证验证"。
- FR-03.2：`used_percent` 原义已用展示。
- FR-08.5：三界面一致投影。
- 调用能力未接入期间：测试调用按钮置灰＋"本 App 未接入"原因（FR-09.4），不静默隐藏。

## 5. 错误恢复

| 错误 | 判定（B） | 恢复 |
| --- | --- | --- |
| 凭证失效 | HTTP 401／403 | 提示 `codex login`（FR-09.6 入口） |
| 无登录 | auth.json 缺失／auth_mode 非 chatgpt／无 access_token | no-auth，同上 |
| 网络 | curl 失败／非 200 | network；同账号旧桶保留 |
| 解析 | 非 JSON／无有效窗口字段 | parse；保旧值 |
| 账号切换 | 旧缓存 `account_id` 与当前不一致 | **不沿用旧账号额度**（B writeFailure 同账号判定）——身份变化隔离（FR-02.7） |
