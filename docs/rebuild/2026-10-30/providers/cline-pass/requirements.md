# cline-pass 需求｜S3 供应商包 v0.1

日期：2026-10-30。证据分级：**A＝2026-10-29 会话实测（待脱敏 fixture 固化）**；**B＝代码现状**（`Sources/TokenHUD/providers/cline/`、`Sources/TokenHUD/mjs/cline-usage-provider.mjs`）。未标注者为目标要求（引用 [04](../../04-global-requirements.md)／[05](../../05-global-technical.md)）。

## 1. 账号与授权

- 账号类型：Cline 订阅账号（Pro/Max 等套餐），以 API Key 为凭证（A：Key 于 app.cline.bot/settings/api-keys 生成）。
- Key 前缀：会话实测记录为 `sk_` 开头（A）；代码 auth-template 注释记录为 `clp_` 开头（B）。**冲突，待核实**，UI 不硬编码前缀校验。
- 内置供应商（manifest `builtin` 语义）：查询与调用 URL 锁定，用户仅可改 Key、测试模型、提示词、定时任务。
- 多实例：一 Key 一账号实例；同套餐可多 Key 并列，身份按 FR-01.2 稳定 UUID，不以 Key 前缀或邮箱推身份。
- Key 由 App 管理并遮罩（FR-02.2），替换／清除为独立意图（FR-02.3）；本包无 CLI／OAuth 来源。

## 2. 额度语义

- 官方端点直接返回套餐用量（A）：`{data:{limits:[{type:"five_hour"|"weekly"|"monthly", percentUsed:int, resetsAt:ISO8601(可含纳秒)}]}}`。
- `percentUsed` 已是百分数（0—100 已用口径），按原义展示"已用 xx%"，不另造分母（FR-03.2）。
- `resetsAt` 为 ISO8601 可带 9 位纳秒小数，转秒级 epoch 展示；到点只标待更新，不证明已重置（FR-03.8）。
- 窗口动态列表：接口返回哪些 type 展示哪些，不硬塞空 5h／周／月（FR-03.5）；未知 type 忽略不猜（B）。
- plan 接口另含 `inferenceCapThreshold`、`currentPeriodEnd`（A）：作为套餐元信息展示候选，语义待核实，不进调度。

## 3. 能力矩阵（能力 × 证据等级）

| 能力 | 结论 | 证据 |
| --- | --- | --- |
| 额度查询 | 支持：官方 usage-limits 端点 | A（200 实测）＋B |
| 模型调用 | 支持：POST `/api/v1/chat/completions`（OpenAI 变体，响应包在 `data.choices`） | A（preset 模型实测 200）＋B（manifest） |
| 模型目录 | GET `/api/v1/models` 返回 440 个模型；仅目录读取，不算调用测试（FR-04.6） | A |
| 自动查询 | 通用 FR-05 规则适用；manifest intervalSec=300（B） | B |
| 定时调用 | 通用 FR-06 规则适用；无证据支持"调用启动窗口"机制，不承诺 | — |
| 分页历史 | nextToken 无效、`cursor=<lastItemId>` 有效——历史接口教训，当前范围未纳入 | A（教训记录） |

## 4. UI 要求（引 FR）

- FR-01.1：首次添加走 cline-pass 模板进入统一编辑器；查询／调用地址只读展示。
- FR-02.2：Key 输入遮罩，已有值空框＝保持原值。
- FR-03.2／FR-03.5：默认"已用 xx%"，窗口列表按返回动态渲染。
- FR-04.1／FR-04.3：发送测试调用前确认完整地址、模型、凭证；默认提示词"只回复OK"、最大输出 16（兼容性见 technical）。
- FR-05／FR-06：自动查询与定时调用独立开关；新调用计划默认 OFF。
- FR-08.5：菜单栏／悬浮窗／HUD 投影同数据简版。

## 5. 错误恢复

| 错误 | 判定 | 恢复 |
| --- | --- | --- |
| 凭证失效 | HTTP 401／403 | 提示到 app.cline.bot 重新生成 Key（FR-09.6 恢复入口） |
| 结构错误 | 200 但无 `data.limits` 数组或无已知桶 | parse 错误，保留旧值标 stale（FR-03.8） |
| 网络 | 无 HTTP 应答／超时 | 连接层失败最多重试 1 次（B）；保旧值 |
| 未配置 | auth 文件无 apiKey | no-auth，阻断自动查询（FR-05.6） |

失败一律保留身份匹配旧桶不清空 UI（B）；失败尝试不推进 lastSuccessAt（FR-09.2）。
