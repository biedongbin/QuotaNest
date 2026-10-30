# cline-pass 技术｜S3 供应商包 v0.1

日期：2026-10-30。证据同 [requirements.md](requirements.md)：A＝2026-10-29 会话实测（待脱敏 fixture 固化），B＝代码现状。

## 1. 端点与认证

### 额度查询（A＋B）
- `GET https://api.cline.bot/api/v1/users/me/plan/usage-limits`
- 认证：`Authorization: Bearer <apiKey>`；`Accept: application/json`
- 脱敏响应样例（结构按实测，值为占位）：
```json
{ "data": { "limits": [
  { "type": "five_hour", "percentUsed": 42, "resetsAt": "2026-10-29T07:00:00.123456789Z" },
  { "type": "weekly",    "percentUsed": 17, "resetsAt": "2026-11-01T00:00:00.000000000Z" }
] } }
```
- 另含 `inferenceCapThreshold`、`currentPeriodEnd`（A，语义待核实，仅展示候选）。

### 模型调用（A）
- `POST https://api.cline.bot/api/v1/chat/completions`，Bearer 同 Key；OpenAI 变体，**响应包在 `data.choices`**（非顶层 `choices`）。
- 实测模型：`@preset/cline-new27-20261022-sonnet55-vertex-global-r1` 返回 200。

### 模型目录（A）
- `GET /api/v1/models` → 440 个模型。仅作目录读取。

## 2. 字段映射规范快照

| 原始字段 | 规范快照字段 | 规则 |
| --- | --- | --- |
| `data.limits[].type` | 窗口标识 | `five_hour→five_hour`、`weekly→seven_day`、`monthly→monthly`；未知 type 忽略 |
| `data.limits[].percentUsed` | `used_percentage` | 已是百分数，clamp 0—100 保留原值（超额原值另存），round 0.1 |
| `data.limits[].resetsAt` | `resets_at`（epoch 秒） | ISO8601 纳秒小数裁到 3 位再解析；非法→null（不伪造） |

成功判据：HTTP 200 **且** `data.limits` 为数组且至少一个已知桶有效（FR-03.7）；空 data／无桶不写成功。

## 3. 默认安全值

- 测试模型：`@preset/cline-new27-20261022-sonnet55-vertex-global-r1`（manifest B；preset 命名随日期滚动，**待核实**更新规则）。
- 提示词"OK"／"只回复OK"、最大输出 16（目标建议 FR-04.3）；**待核实**：completions 变体是否接受 `max_tokens:16` 最小预算、是否有更高硬下限。
- 单请求 8s、连接层失败重试 1 次、总预算 20s 内（B，符合 05 第 5 节）；401／403 不重试。
- 凭证文件：`~/.claude/hud/.cline-usage-auth.json`（B 现状；目标存储方案见 05 第 9 节，S5 定迁移）。

## 4. 对接 05 调度

- 自动查询：间隔 manifest 300s（B）＝全局默认，无 provider 例外声明。
- due／合并键／并发／唤醒按 05 第 5 节通用规则；无例外。
- 定时调用：按 05 第 6—7 节；本包**无窗口启动机制证据**，调用成功不解读为窗口重置（05 第 7 节末条）。

## 5. 业务成功判据

1. 手动查询→三个界面同快照；`percentUsed` 原义"已用"展示。
2. 测试调用→独立结果区显示 `data.choices` 解析文本；不覆盖额度区（FR-04.4）。
3. 401→旧值保留＋"到 app.cline.bot 重新生成"入口。

## 6. 待验证清单

| 项 | 影响 | 状态 |
| --- | --- | --- |
| 脱敏 fixture 固化（usage-limits／completions 200 样本） | S4 追溯、S6 对照 | 未固化 |
| Key 前缀 `sk_` vs `clp_` 冲突 | UI 校验不硬编码即可，描述待统一 | 冲突待核实 |
| `inferenceCapThreshold`／`currentPeriodEnd` 语义 | 展示口径 | 待核实 |
| `max_tokens:16` 兼容性 | 默认安全值是否需上调 | 待核实 |
| preset 模型命名滚动规则 | 默认测试模型失效风险 | 待核实 |
| 历史接口 `cursor=<lastItemId>` 分页 | 当前范围未用；如纳入须重新取证 | 备查（A 教训） |
