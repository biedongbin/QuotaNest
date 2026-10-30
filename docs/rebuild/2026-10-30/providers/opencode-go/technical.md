# opencode-go 技术｜S3 供应商包 v0.1

日期：2026-10-30。证据 B＝代码现状（`oc-go-usage-provider.mjs`、`providers/opencode-go/`）。响应样例为代码推断结构＋占位值。

## 1. 端点与认证

### 额度查询（B）
- `GET https://opencode.ai/zen/go/v1/usage`（代码强制 URL 含 `/usage`；auth.apiUrl 可覆盖）
- 认证：`Authorization: Bearer <refreshApiKey>`
- 脱敏响应样例（结构按代码推断，值占位）：
```json
{ "usage": {
  "rolling": { "percent": 31.0, "resetsAt": "2026-10-30T09:00:00Z" },
  "weekly":  { "percent": 12.0, "resetsAt": "2026-11-02T00:00:00Z" },
  "monthly": { "percent": 5.0,  "resetsAt": "2026-11-01T00:00:00Z" } } }
```

### 模型调用（B manifest）
- `POST https://opencode.ai/zen/go/v1/chat/completions`，OpenAI 协议，`Authorization: Bearer <key>`
- 测试模型：`deepseek-v4-flash`（B）

## 2. 字段映射规范快照（B）

| 原始字段 | 规范字段 | 规则 |
| --- | --- | --- |
| `usage.rolling` | five_hour 窗口 | 桶存在才有 |
| `usage.weekly` | seven_day 窗口 | 同上 |
| `usage.monthly` | monthly 窗口 | 同上 |
| 桶内 `percent` | `used_percentage` | number 原义；非 number→null |
| 桶内 `resetsAt` | `resets_at`（epoch 秒） | ISO→`Date.parse` 毫秒÷1000；非法→null |

成功判据：HTTP 层可达 **且** body 含 `usage` 对象（B 现状未显式校验 HTTP 状态——curl `-s` 吞状态码，非 200 的 JSON 错误体若无 `usage` 走 parse 错，**待核实**：目标实现补显式状态校验，满足 FR-03.7）。

## 3. 默认安全值

- 测试模型 `deepseek-v4-flash`（B）；提示词"只回复OK"、最大输出 16（目标建议）；**待核实** chat/completions 接受度。
- 超时 10s（B）；无内建重试。
- 凭证文件：`~/.claude/hud/.oc-go-usage-auth.json`（B；目标存储见 05 第 9 节）。
- 调用协议注意：manifest `refreshProtocol:"openai"` 且 refreshHeader 无 anthropic-version——OpenAI 变体，不拼 /v1/messages。

## 4. 对接 05 调度

- 自动查询 intervalSec=60（B）vs 全局 300：S5 取舍（同 glm/gpt/ollama）。
- due／合并／并发／唤醒按 05 第 5 节通用规则；无 provider 例外声明。
- 失败保旧桶无身份核对（B 缺陷）：目标按 05 第 3 节以 credentialRevision 复核后再保旧值。
- 定时调用按 05 第 6—7 节；无窗口启动机制证据，不承诺。

## 5. 业务成功判据

1. 查询成功→rolling／周／月三桶"已用 xx%"＋重置倒计时（ISO 正确转 epoch 秒）。
2. 无 `usage` 对象→parse 错误，旧值标 stale 不清空。
3. 测试调用→chat/completions 独立结果区；结果不覆盖额度区。

## 6. 待验证清单

| 项 | 影响 | 状态 |
| --- | --- | --- |
| usage 端点真实样本（脱敏） | 字段映射 S4 追溯 | 待取证 |
| `percent` 已用/剩余口径 | 展示方向正确性 | 待核实 |
| rolling 窗口长度（是否≈5h） | 窗口标签 | 待核实 |
| 凭证失效形态（HTTP 状态／body） | auth 错误判定 | 待核实 |
| HTTP 状态显式校验补齐 | FR-03.7 合规 | 目标待实现（S6） |
| chat/completions `max_tokens:16` 兼容 | 默认安全值 | 待核实 |
| Zen API 文档来源（官方/社区） | 权威引用 | 待核实 |
