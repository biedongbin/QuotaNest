# gpt-codex 技术｜S3 供应商包 v0.1

日期：2026-10-30。证据 B＝代码现状（`gpt-usage-provider.mjs`、`providers/gpt/`）。响应样例为代码推断结构＋占位值。

## 1. 端点与认证

### 额度查询（B）
- `GET https://chatgpt.com/backend-api/wham/usage`
- 认证：`Authorization: Bearer <access_token>`＋（有 account_id 时）`chatgpt-account-id: <id>`＋`Accept: application/json`
- 凭证读取：auth 指针 `~/.claude/hud/.gpt-usage-auth.json` 的 `codexAuthFile`（绝对路径）→ 否则 `${CODEX_HOME:-~/.codex}/auth.json`；**只读不写不刷新**
- 脱敏响应样例（结构按代码推断，值占位）：
```json
{ "rate_limit": {
  "primary_window":   { "used_percent": 63.4, "reset_at": 1779500400 },
  "secondary_window": { "used_percent": 28.1, "reset_after_seconds": 259000 }
} }
```

### 模型调用
- 未接入（manifest 无 refreshUrl）。ChatGPT 订阅的 Codex 调用路径是否可从 App 发起，**待取证**；取证前不提供调用配置。

## 2. 字段映射规范快照（B）

| 原始字段 | 规范字段 | 规则 |
| --- | --- | --- |
| `rate_limit`｜`rate_limits`｜`rate_limits_by_limit_id.codex` | 窗口容器 | 依序取第一个对象 |
| `primary_window`／`primary` | five_hour | 先命中先用 |
| `secondary_window`／`secondary` | seven_day | 同上 |
| `used_percent`｜`percent_used` | `used_percentage` | 数值化失败→null（不伪造）；clamp 0—100 保留原值，round 0.1 |
| `reset_at`｜`resets_at`｜`resetAt` | `resets_at`（epoch 秒） | 数值：`<1e12` 按秒否则毫秒；纯数字串同规则；字符串按 ISO；再缺则 `reset_after_seconds` 相对秒加 now |
| `tokens.account_id` | 身份关联字段 | 缓存 `account_id`，失败时同账号才保旧值 |

成功判据：HTTP 200 **且** 解析出至少一个有效窗口（FR-03.7）。

## 3. 默认安全值

- 无测试模型／调用配置（调用未接入）；定时调用计划不可启（缺配置，FR-06）。
- 超时：connect 8s、总 12s（B）；无内建重试。
- 凭证文件：本包 App 侧仅 auth 指针（不含凭证），真凭证在 `~/.codex/auth.json`（B；目标存储见 05 第 9 节）。

## 4. 对接 05 调度

- 自动查询 intervalSec=60（B manifest）vs 全局 300：同 glm，S5 取舍。
- 401／403 不重试、保旧值（B）；429 未特判——目标按 05 第 5 节通用 429 规则执行，**待核实** wham 端点 429 行为。
- 唤醒补一次、并发位按 05 第 5 节。
- 定时调用：调用能力未接入前计划入口标"未接入"（FR-09.4），无调度。

## 5. 业务成功判据

1. 查询成功→primary/secondary 两桶"已用 xx%"＋重置倒计时；秒/毫秒自动判定正确。
2. 401→"codex login"恢复入口；旧值标 stale 不清空。
3. Codex 登录换账号→旧 account_id 缓存不沿用（身份隔离）。

## 6. 待验证清单

| 项 | 影响 | 状态 |
| --- | --- | --- |
| wham/usage 真实响应样本（脱敏，含兼容集三种容器形态） | 字段映射 S4 追溯 | 待取证 |
| ChatGPT 订阅经 API 的可调用路径（Codex responses/chat 端点） | 调用能力能否开放 | 待取证 |
| 多 CODEX_HOME 多实例语义 | 多账号支持 | 待核实 |
| wham 429／限流形态 | 05 第 5 节 429 规则适配 | 待核实 |
| token 过期前 refresh 窗口内读到的 access_token 可用性 | 查询失败率 | 待核实 |
| intervalSec 60 vs 全局 300 | 调度声明 | 待核实（S5） |
