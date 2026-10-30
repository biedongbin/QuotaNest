# generic-openai-anthropic 技术｜S3 供应商包 v0.1

日期：2026-10-30。证据 B＝代码现状（内置 manifest 调用声明归纳）。本包只定义调用协议契约；额度查询不承诺兼容。

## 1. 协议族与请求形态

### OpenAI 族（chat/completions 变体）
- `POST <用户配置完整 endpoint>`，`Authorization: Bearer <key>`
- 请求体（测试调用默认）：
```json
{ "model": "<用户自填>", "max_tokens": 16, "messages": [ { "role": "user", "content": "只回复OK" } ] }
```
- 成功响应形态（脱敏占位）：`{ "choices": [ { "message": { "content": "OK" } } ] }`
- 变体注意：部分网关响应包在 `data.choices`（B：cline）；responses 变体（`/responses` 端点）**待核实**后再开放，不默认拼接。

### Anthropic 族
- `POST <用户配置完整 endpoint>`（典型 `.../v1/messages`），头：`Authorization: Bearer <key>`＋`anthropic-version: 2023-06-01`＋`content-type: application/json`
- 请求体（测试调用默认）：
```json
{ "model": "<用户自填>", "max_tokens": 16, "messages": [ { "role": "user", "content": "只回复OK" } ] }
```
- 成功响应形态（脱敏占位）：`{ "content": [ { "type": "text", "text": "OK" } ] }`

## 2. 字段映射规范快照

| 项 | 规则 |
| --- | --- |
| 响应判定 | OpenAI 族：HTTP 2xx 且可定位文本（`choices[0].message.content`，兼容 `data.choices`）；Anthropic 族：2xx 且 `content[].text` 有非空项 |
| 失败 | 非 2xx／结构不匹配→调用失败，展示状态码＋响应前 80 字符（脱敏）；不重试 |
| 结果不明 | POST 已发后超时／断连→"结果不确定，可能已消费"（FR-04.5） |
| 无额度映射 | 本包无规范快照窗口字段；额度区恒为"不支持" |

## 3. 默认安全值

- 提示词"只回复OK"、`max_tokens:16`（目标建议 FR-04.3）；部分兼容网关不接受 16 时由用户显式上调，App 记录该账号的实际上调值，不用目录首项或大额默认。
- 模型名：用户自填必填，无默认值、无目录兜底。
- 请求超时 20 秒（FR-04.4）；已发送 POST 不自动重试（05 第 6 节）。
- 凭证：App 自有凭证存储（05 第 9 节，0600＋原子替换）；endpoint 全量用户可编辑。

## 4. 对接 05 调度

- 不注册查询执行器（无额度能力）；无 due／间隔／429 查询语义。
- 定时调用：按 05 第 6—7 节全量规则——planRevision、跨版本防重、started 原子落盘、DST／时区、并发每账号 1 全局 2、错过不补发。
- 调用目标 targetFingerprint 含协议族＋完整 endpoint＋模型＋凭证版本，不含 key 明文（05 第 7 节）。

## 5. 业务成功判据

1. OpenAI 族测试调用→结果区显示回复文本；`data.choices` 兼容形态同样命中。
2. Anthropic 族测试调用→`content[].text` 拼接展示。
3. 协议错配（如 Anthropic 协议打 chat/completions 地址）→失败明示状态码与响应摘要，不伪成功。
4. 定时计划到期→按已保存授权目标执行，结果独立落盘。

## 6. 待验证清单

| 项 | 影响 | 状态 |
| --- | --- | --- |
| responses 变体（/responses）是否纳入 | OpenAI 族覆盖面 | 待核实 |
| `data.choices` 网关变体清单 | 响应解析兼容集 | 待核实 |
| `max_tokens:16` 在主流网关接受度采样 | 默认安全值 | 待核实 |
| anthropic-version 头是否需可配置 | 兼容性 | 待核实 |
| 每协议族脱敏 fixture（成功/401/结构错） | S4 追溯 | 待固化 |
