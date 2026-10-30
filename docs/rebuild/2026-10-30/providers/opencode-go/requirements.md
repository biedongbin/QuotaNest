# opencode-go 需求｜S3 供应商包 v0.1

日期：2026-10-30。证据分级：**B＝代码现状**（`Sources/TokenHUD/mjs/oc-go-usage-provider.mjs`、`Sources/TokenHUD/providers/opencode-go/`）。README 边界注记"服务能力与字段来源待核实"。目标要求引用 [04](../../04-global-requirements.md)／[05](../../05-global-technical.md)。

## 1. 账号与授权

- 账号类型：OpenCode（opencode.ai）Zen API 账号，API Key。
- 凭证：bearer——`refreshApiKey` 字段即查询用 API Key（B 脚本注释）；调用同 Key（manifest `refreshAuth:"bearer"`）。
- 内置供应商：查询 URL 锁定 `opencode.ai/zen/go/v1/usage`（B，代码强制含 `/usage`）；调用 `opencode.ai/zen/go/v1/chat/completions`（OpenAI 协议，manifest B）。
- 多实例：多 Key 并列，身份按 FR-01.2。
- 演进背景（B 注释）：旧路线为 workspace 页 SSR HTML 解析，网站改客户端渲染后废弃，现走 Zen API v1——HTML 解析路径不复活。

## 2. 额度语义

- 官方端点（B）：`GET https://opencode.ai/zen/go/v1/usage`，Bearer key。
- 响应结构（B 代码推断）：`{usage:{rolling:{...}, weekly:{...}, monthly:{...}}}`；每桶 `percent`（已用百分数）＋`resetsAt`（ISO8601）。
- 三窗口：rolling（≈5h 语义，**待核实**滚动窗口长度）／weekly／monthly；接口返回才展示，缺失桶为 null 不造空（FR-03.5）。
- 无成功响应样本，`percent` 口径（已用 vs 剩余）按 B 命名推定已用——**待核实**。

## 3. 能力矩阵

| 能力 | 结论 | 证据 |
| --- | --- | --- |
| 额度查询 | 支持：Zen API v1 usage | B |
| 模型调用 | 支持：/v1/chat/completions（OpenAI 协议 bearer），manifest 声明，无实测记录 | B |
| 自动查询 | 通用 FR-05；intervalSec=60（B） | B |
| 定时调用 | 通用 FR-06；无窗口启动机制证据 | — |

## 4. UI 要求（引 FR）

- FR-01.1：模板统一编辑器；usage／chat/completions 端点只读。
- FR-02.2：Key 遮罩、空框保持原值。
- FR-03.2："已用 xx%"；percent 原义（口径待核实后固化）。
- FR-03.5：rolling／周／月三桶动态渲染。
- FR-04.1／FR-04.3：测试调用默认模型 `deepseek-v4-flash`（B）。
- FR-08.5：三界面一致。

## 5. 错误恢复

| 错误 | 判定（B） | 恢复 |
| --- | --- | --- |
| 网络 | curl 失败／超时 10s | network；stale 保旧桶 |
| 解析 | 非 JSON／无 `usage` 对象 | parse；stale 保旧桶 |
| 未配置 | auth 无 refreshApiKey | no-auth，阻断自动查询 |
| 凭证失效 | B 脚本未特判 body 401——**待核实**失效形态；目标按 HTTP 401／403→auth 处理 | 换 Key |

注：B 失败保留旧桶但无账号身份核对（对比 gpt 的 account_id 判定）——目标实现按 05 第 3 节加身份复核。
