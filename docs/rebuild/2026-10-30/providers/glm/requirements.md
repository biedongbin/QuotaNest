# glm 需求｜S3 供应商包 v0.1

日期：2026-10-30。证据分级：**B＝代码现状**（`Sources/TokenHUD/mjs/glm-usage-provider.mjs`、`Sources/TokenHUD/providers/glm/manifest.json`、`auth-template.json`）。无接口级实测样本，字段语义中超出代码可读部分标"待核实"。目标要求引用 [04](../../04-global-requirements.md)／[05](../../05-global-technical.md)。

## 1. 账号与授权

- 账号类型：智谱 GLM 开放平台 API Key 账号（bigmodel.cn）。
- 凭证：API Key，bearer 方式；查询走 `Authorization: Bearer <key>`（B manifest `queryAuth:"bearer"`）。
- 内置供应商：查询 URL（monitor 端点）锁定；调用走 Anthropic 兼容 `open.bigmodel.cn/api/anthropic/v1/messages`（B manifest `refreshProtocol:"anthropic"`，需 `anthropic-version: 2023-06-01` 头）。
- 多实例：多 Key 并列，身份按 FR-01.2 稳定 UUID。
- JWT 历史（B 脚本注释与既知约束）：既往曾用 JWT 解析路径，现行代码为纯 bearer API Key；JWT 相关逻辑不进主框架。**待核实**：JWT 历史路径是否仍需保留兼容。

## 2. 额度语义

- 官方端点（B auth-template）：`GET https://bigmodel.cn/api/monitor/usage/quota/limit`，body 认证失败判定 `code===401`、成功 `code===200`（HTTP 层可能恒 200，业务码在 body）。
- 响应结构（B 代码推断）：`data.limits` 数组，按 `unit` 匹配窗口——`unit:3`＝5h 桶、`unit:6`＝周桶（**待核实** unit 语义枚举）。
- 百分比：`percentage` 字段为已用百分数（B `percentField`）；无现成百分比时可按 `remainingField` 100 减或 `used/total` 自算（泛用解析路径，GLM 当前用 percentField）。
- 重置：`nextResetTime`（毫秒 epoch，B `resetsAtUnit:"ms"`）；5h 桶另有固定时刻兜底 `resetsAtTimes:["06:30","11:31","16:32"]`（B）——固定三时刻语义**待核实**（是否官方文档化周期）。
- 窗口列表按返回动态展示；缺失窗口不造空桶（FR-03.5）。

## 3. 能力矩阵

| 能力 | 结论 | 证据 |
| --- | --- | --- |
| 额度查询 | 支持：monitor quota/limit 端点 | B |
| 模型调用 | 支持：Anthropic 兼容 /v1/messages，bearer＋anthropic-version | B（manifest 声明，无实测记录） |
| 自动查询 | 通用 FR-05；manifest intervalSec=60（B，低于全局默认 300——provider 更频繁，需声明下限理由） | B |
| 定时调用 | 通用 FR-06；无窗口启动机制证据 | — |
| 风控特性 | bigmodel 对 node/undici fetch 风控（body code:401），须 curl UA＋TLS 指纹（B 注释）——实现层约束 | B |

## 4. UI 要求（引 FR）

- FR-01.1：模板进入统一编辑器；monitor／anthropic 端点只读展示。
- FR-02.2：Key 遮罩；空框＝保持原值。
- FR-03.2："已用 xx%"默认；percentage 原义已用。
- FR-03.7：HTTP 200 但 body `code!=200` 不得当成功——本包业务码在 body，是 FR-03.7 典型场景。
- FR-04.1／FR-04.3：测试调用确认 anthropic 协议、完整 URL、模型（默认 `glm-4.7`，B）。
- FR-08.5：三界面投影一致。

## 5. 错误恢复

| 错误 | 判定（B） | 恢复 |
| --- | --- | --- |
| 凭证失效 | body `code===401` | 换 Key 后显式查询；旧值标 stale 保留 |
| 业务错误 | body `code` 非 200 非 401 | `api:<code>` 错误态；保旧值 |
| 网络 | curl 失败 | network；stale 保旧桶 |
| 解析 | 非 JSON | parse；stale 保旧桶 |
| 未配置 | auth 文件缺 apiUrl | no-auth，阻断自动查询 |

失败不推进 lastSuccessAt（FR-09.2）；GLM 脚本失败保留旧桶（B），符合 FR-03.8。
