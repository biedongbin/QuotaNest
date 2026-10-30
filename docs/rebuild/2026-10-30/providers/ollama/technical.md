# ollama 技术｜S3 供应商包 v0.1

日期：2026-10-30。证据 B＝代码现状（`ollama-usage-provider.mjs`、`providers/ollama/`）。响应样例为代码推断结构＋占位值。

## 1. 端点与认证

### 额度查询（B）
- `GET https://ollama.com/api/balance`（代码强制 URL 含 `/api/balance`；auth-template 的 `/api/usage` 为旧值，**待更新核实**）
- 认证：`Authorization: Bearer <key>`＋`Accept: application/json`；key 取 headers.Authorization 或 refreshApiKey
- 脱敏响应样例（双形态，结构按代码推断，值占位）：
```json
// legacy plan
{ "included": {
  "session": { "remaining_percent": 88.5, "resets_at": "2026-10-30T12:00:00Z" },
  "weekly":  { "remaining_percent": 95.2, "resets_at": "2026-11-02T00:00:00Z" } } }

// 新计费 plan
{ "included": {
  "balance_usd": 8.4, "allowance_usd": 10.0,
  "period": { "until": "2026-11-01T00:00:00Z" } } }
```

### 模型调用（B manifest）
- `POST https://ollama.com/v1/messages`，Anthropic 协议，`Authorization: Bearer <key>`＋`anthropic-version: 2023-06-01`
- 测试模型：`deepseek-v4-flash`（B）

## 2. 字段映射规范快照（B）

| 原始字段 | 规范字段 | 规则 |
| --- | --- | --- |
| `included.session.remaining_percent` | five_hour `used_percentage` | `100−remaining`，round 0.1（同一 100% 配额，FR-03.3 允许） |
| `included.weekly.remaining_percent` | seven_day `used_percentage` | 同上 |
| `included.*.resets_at` | `resets_at` | 原值保留（ISO 字符串；目标统一转 epoch 秒——**待核实**当前格式是 ISO 还是 epoch） |
| `included.balance_usd`／`allowance_usd` | monthly `used_percentage` | `(1−balance/allowance)×100`；allowance≤0→0 |
| `included.period.until` | monthly `resets_at` | ISO→epoch 秒 |
| body `error` | 错误态 | `too many requests`／`invalid credentials` |

成功判据：HTTP 200 **且** `included` 存在且命中 legacy 或新计费任一形态（FR-03.7）；未知形态→parse 错误。
余额精度：金额按 05 第 4 节走十进制定点，不二进制浮点直接运算展示（现状代码用浮点，目标实现修正）。

## 3. 默认安全值

- 测试模型 `deepseek-v4-flash`（B）；提示词"只回复OK"、最大输出 16（目标建议）；**待核实** /v1/messages 接受度。
- 超时：connect 8s、总 12s（B）；**单次尝试不内重试**（B，限频 10 req/min 约束）——provider 级声明，比 05 第 5 节"连接失败重试 1 次"更严格，按 provider 声明优先保留并论证（限频叠加风险）。
- 凭证文件：`~/.claude/hud/.ollama-usage-auth.json`（B；目标存储见 05 第 9 节）。
- 实现（B 注释）：curl 子进程（TUN fake-IP 代理环境 node fetch 不通）——同 glm 属实现层约束，S5 评估。

## 4. 对接 05 调度

- 自动查询 intervalSec=60（B）＝1 req/min，低于限频阈值，单 Key 安全；**待核实**多账号全局并发下的总量。全局默认 300（FR-05.1），60 属旧 HUD 需求，S5 取舍。
- 429 类（body too many requests）：按 FR-05.5，缺失 Retry-After 时暂停至少 max(interval,60s)；不内重试（B 声明优先）。
- 定时调用按 05 第 6—7 节；无窗口启动机制证据，不承诺。

## 5. 业务成功判据

1. legacy 形态→5h＋周两桶"已用 xx%"（100 减换算）＋重置倒计时。
2. 新计费形态→月桶已用百分比＋USD 余额分列展示，币种标注。
3. body too many requests→限频态，旧值保留，下一轮自然恢复。

## 6. 待验证清单

| 项 | 影响 | 状态 |
| --- | --- | --- |
| /api/balance 真实样本（两种形态各一，脱敏） | 字段映射 S4 追溯 | 待取证 |
| auth-template apiUrl 旧值 /api/usage 清理 | 配置正确性 | 待更新核实 |
| `resets_at` 实际格式（ISO vs epoch） | 时间映射 | 待核实 |
| legacy／新计费与套餐的对应关系、可否并存 | 窗口展示逻辑 | 待核实 |
| /v1/messages `max_tokens:16` 兼容 | 默认安全值 | 待核实 |
| 限频 10 req/min 精确值与多账号总量 | 调度预算 | 待核实 |
