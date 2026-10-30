# ollama 需求｜S3 供应商包 v0.1

日期：2026-10-30。证据分级：**B＝代码现状**（`Sources/TokenHUD/mjs/ollama-usage-provider.mjs`、`Sources/TokenHUD/providers/ollama/`）。README 边界注记"账号与额度来源的真实语义待核实"。目标要求引用 [04](../../04-global-requirements.md)／[05](../../05-global-technical.md)。

## 1. 账号与授权

- 账号类型：Ollama Cloud 账号，API Key（`ollama.com` 生成）。
- 凭证：bearer——查询头 `Authorization: Bearer <key>`，auth 中 `refreshApiKey` 兜底（B）。
- 内置供应商：查询 URL 锁定 `ollama.com/api/balance`（B，代码强制含 `/api/balance` 才用覆盖值）；调用 `ollama.com/v1/messages`（Anthropic 协议，manifest B）。
- 多实例：多 Key 并列；同一 Key 的额度与计费套餐绑定（legacy plan vs 新计费 plan，B），**待核实**两套餐下同 Key 语义。

## 2. 额度语义

官方端点 `GET /api/balance`，两种返回形态（B），按先命中先解析：

| 套餐形态 | 字段 | 语义 |
| --- | --- | --- |
| legacy plan | `included.session/weekly.remaining_percent`（0—100 剩余）＋`resets_at` | 剩余百分比→已用＝100 减（符合 FR-03.3 同一 100% 配额才可减）；5h＋周两桶 |
| 新计费 plan | `included.balance_usd`／`allowance_usd`＋`period.until` | 美元额度：已用百分比＝(1−balance/allowance)×100，月桶；余额标币种 USD（FR-03.6），不与 token 桶合计 |

- 背景（B 注释）：2026-10 起 `/api/usage` 移除 limits 字段，限额迁至 `/api/balance`；旧 auth-template 仍写 `/api/usage`（B，**待更新核实**）。
- 窗口按返回形态动态展示：legacy 显示 5h＋周、新计费显示月桶，不混造（FR-03.5）。
- 限频：服务端 ~10 req/min（B 注释：内重试会与下一轮叠加超限）——provider 级请求预算约束。

## 3. 能力矩阵

| 能力 | 结论 | 证据 |
| --- | --- | --- |
| 额度查询 | 支持：/api/balance（双形态解析） | B |
| 模型调用 | 支持：/v1/messages（Anthropic 协议 bearer），manifest 声明，无实测记录 | B |
| 自动查询 | 通用 FR-05；intervalSec=60（B）与限频 10 req/min 的关系**待核实**（60s 一轮＝1 req/min，单 Key 安全；多账号多 Key 各自独立） | B |
| 定时调用 | 通用 FR-06；无窗口启动机制证据 | — |
| 错误语义 | body `error:"too many requests"`／`"invalid credentials"`（B） | B |

## 4. UI 要求（引 FR）

- FR-01.1：模板统一编辑器；balance／messages 端点只读。
- FR-02.2：Key 遮罩、空框保持原值。
- FR-03.2／FR-03.6：legacy 形态"已用 xx%"；新计费形态已用百分比＋USD 余额分列，不把美元画成 token 窗口。
- FR-04.1／FR-04.3：测试调用默认模型 `deepseek-v4-flash`（B）。
- FR-08.5：三界面一致。

## 5. 错误恢复

| 错误 | 判定（B） | 恢复 |
| --- | --- | --- |
| 凭证无效 | body `error:"invalid credentials"` | 换 Key；旧值 stale 保留 |
| 限频 | body `error:"too many requests"` | 等待下一轮；App 侧不内重试（B 设计）；目标按 FR-05.5 至少 max(interval,60s) |
| 网络 | curl 失败／非 200 | network；保旧值 |
| 解析 | 非 JSON／无 `included`／未知形态 | parse；保旧值 |
| 未配置 | 无 Bearer key | no-auth |
