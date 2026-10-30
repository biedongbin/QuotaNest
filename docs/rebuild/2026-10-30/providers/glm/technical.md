# glm 技术｜S3 供应商包 v0.1

日期：2026-10-30。证据 B＝代码现状（`glm-usage-provider.mjs`、`providers/glm/`）；接口字段无实测样本，样例为代码推断结构＋占位值。

## 1. 端点与认证

### 额度查询（B）
- `GET https://bigmodel.cn/api/monitor/usage/quota/limit`（auth-template `apiUrl`，可覆盖）
- 认证：headers 动态构造（auth.headers），现模板为 `authorization: <Bearer key>`、`accept:`
- 脱敏响应样例（结构按代码推断，值占位）：
```json
{ "code": 200, "data": { "limits": [
  { "unit": 3, "percentage": 55.0, "nextResetTime": 1779500000000 },
  { "unit": 6, "percentage": 12.0, "nextResetTime": 1779900000000 }
] } }
```

### 模型调用（B manifest）
- `POST https://open.bigmodel.cn/api/anthropic/v1/messages`，Anthropic 协议变体
- 头：`Authorization: Bearer <key>`＋`anthropic-version: 2023-06-01`
- 测试模型：`glm-4.7`（B）

## 2. 字段映射规范快照（B）

| 原始字段 | 规范字段 | 规则 |
| --- | --- | --- |
| `data.limits[]` + `unit:3` | five_hour 窗口 | match 精确等值 |
| `data.limits[]` + `unit:6` | seven_day 窗口 | 同上 |
| `percentage` | `used_percentage` | 已用百分数原义 |
| `nextResetTime` | `resets_at`（epoch 秒） | 毫秒÷1000 |
| （缺失时）固定时刻 | `resets_at` | 5h 桶兜底 `06:30/11:31/16:32` 最近下一刻，本地时区 |
| body `code` | 业务状态 | 401→auth；非 200→api 错；200→继续解析 |

成功判据：body `code===200` **且** limits 中至少一桶解析出有效 percentage（FR-03.7 双重校验）。

## 3. 默认安全值

- 测试模型 `glm-4.7`（B）；提示词"只回复OK"、最大输出 16（目标建议）；**待核实** anthropic 兼容端点 `max_tokens:16` 接受度。
- 超时 8s（B）；无内建重试（失败即 stale，下一轮再试）。
- 凭证文件：`~/.claude/hud/.glm-usage-auth.json`（B；目标存储见 05 第 9 节）。
- **实现约束（B 注释）**：bigmodel 风控 node/undici fetch（body code:401），请求须走 curl 子进程（UA＋TLS 指纹）。目标架构 S5 定，但任何重写须保留此约束或重新验证 fetch 可通。

## 4. 对接 05 调度

- 自动查询 intervalSec=60（B manifest）低于全局默认 300：作为 provider 严格声明保留，理由＝statusline 60s TTL 联动（B）。目标 App 中查询间隔默认 300（FR-05.1），60s 属旧 HUD 需求；**S5 决定**是否沿用 60 下限。
- due／合并／并发按 05 第 5 节；429 规则未见 GLM 特例（body 风控 401 已按 auth 处理）。
- 定时调用按 05 第 6—7 节；无窗口启动机制证据，不承诺。

## 5. 业务成功判据

1. 查询成功→`unit:3/6` 两桶各展示"已用 xx%"＋重置倒计时；`nextResetTime` 毫秒正确转秒。
2. body `code:401`（HTTP 200）→识别为凭证失效而非成功，旧值保留。
3. 测试调用→anthropic /v1/messages 独立结果区，不碰额度区。

## 6. 待验证清单

| 项 | 影响 | 状态 |
| --- | --- | --- |
| monitor 端点真实响应样本（脱敏） | 字段映射 S4 追溯 | 待取证 |
| `unit` 枚举完整语义（3/6 之外是否有月桶） | 窗口列表 | 待核实 |
| 固定三时刻 `06:30/11:31/16:32` 官方依据 | resetsAt 兜底合法性 | 待核实 |
| JWT 历史路径是否需兼容 | 迁移范围 | 待核实 |
| anthropic 端点 `max_tokens:16` 兼容 | 默认安全值 | 待核实 |
| fetch 风控约束在目标 Swift/脚本架构下的等价物 | 实现路径 | 待核实（S5） |
| intervalSec 60 与全局 300 的取舍 | 调度声明 | 待核实（S5） |
