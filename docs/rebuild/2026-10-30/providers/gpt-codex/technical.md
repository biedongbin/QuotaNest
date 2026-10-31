# gpt-codex 技术｜S3 供应商包 v0.2

日期：2026-10-30。证据 **A＝本日一次官方只读响应**；**B＝代码现状**（`gpt-usage-provider.mjs`、`providers/gpt/`）。三种兼容容器、附加模型和错误行为的 fixture 是离线测试，不作为真实接口返回的证据。

## 1. 端点与认证

### 额度查询（A、B）

- `GET https://chatgpt.com/backend-api/wham/usage`
- 认证：`Authorization: Bearer <access_token>`＋有 account_id 时的 `chatgpt-account-id: <id>`＋`Accept: application/json`。
- 凭证读取：auth 指针 `~/.claude/hud/.gpt-usage-auth.json` 的 `codexAuthFile`（绝对路径）→ 否则 `${CODEX_HOME:-~/.codex}/auth.json`；**只读不写不刷新**。
- 2026-10-30 一次受限官方只读请求所得安全字段（A）：

```json
{
  "plan_type": "prolite",
  "rate_limit": {
    "primary_window": {
      "used_percent": 18,
      "limit_window_seconds": 604800,
      "reset_at": 1793776498,
      "reset_after_seconds": 426097
    },
    "secondary_window": null
  }
}
```

HTTP 200；本次没有有效次窗口。上例中的 null 代表缺失或 null 的无有效对象情况，不要求接口一定显式返回该键。`prolite` 仅照录后端字段，不推断商业套餐名、套餐永久窗口数量或滚动／自然周机制。安全样本不含账号、邮箱、token 或完整认证响应。

### 模型调用

未接入（manifest 无 refreshUrl）。ChatGPT 订阅的 Codex 调用路径是否可从 App 发起，**待取证**；取证前不提供调用配置。

## 2. 字段映射规范快照（B）

| 原始字段 | 规范字段 | 规则 |
| --- | --- | --- |
| `rate_limit`｜`rate_limits`｜`rate_limits_by_limit_id.codex` | 主额度容器 | 依序取第一个含有效百分比窗口的对象；无效或空对象不阻断后续兼容容器 |
| `primary_window`／`primary` | 主额度窗口角色 | 同角色别名只取一个有效对象，不据角色猜周期 |
| `secondary_window`／`secondary` | 次额度窗口角色 | 同上；null、缺失或无有效百分比不输出空卡 |
| `limit_window_seconds=18000` | `windows` 的“5小时”及 `five_hour` | 明确周期＝5 小时；只在主额度的该周期唯一时投影 legacy 桶 |
| `limit_window_seconds=604800` | `windows` 的“本周”、`period="7天"` 及 `seven_day` | 明确周期＝7 天，不由窗口角色、套餐名或倒计时推断 |
| 其他正数 `limit_window_seconds` | 可读 `windows.label/period` | 优先用整数小时，否则整数分钟，否则秒；例如 86400→“24小时”；不伪造 legacy 桶 |
| 缺失／非法／非正 `limit_window_seconds` | 中性窗口标签＋`period="周期未知"` | “主额度窗口”／“次额度窗口”；真实重置时刻不能代替周期 |
| `used_percent`｜`percent_used` | `used_percentage` | 有限数值或非空数值串；缺失／null／空串／NaN／布尔值不输出窗口；真实 0 保留；沿用 clamp 0—100、round 0.1 |
| `reset_at`｜`resets_at`｜`resetAt` | `resets_at`（epoch 秒） | 数值 `<1e12` 按秒，否则毫秒；纯数字串同规则；字符串按 ISO；再缺则 `reset_after_seconds`／`resetAfterSeconds` 相对秒加 now |
| `additional_rate_limits[].rate_limit|rate_limits` | 具名附加动态窗口 | 用 `metered_feature`，否则 `limit_name` 标识额度组，标签带名称；有效窗口才登记身份 |
| `rate_limits_by_limit_id` 的其他键 | 其他模型动态窗口 | 保留键名及周期；与前述相同 identity 的别名不重复，不能用相同数值去合并不同身份 |
| `tokens.account_id` | 身份关联字段 | 缓存 `account_id`，失败时同账号才保旧值 |

主、附加模型相同周期时分别展示，附加窗口不覆盖主 legacy 桶。同一主额度有两个同周期约束时，动态标签增加“主／次额度窗口”区别，旧单一桶留空，不能任取一个代表全部。附加不同 identity 恰好同名时标签补 identity；空对象不产卡。

当前实测样本应输出：

```json
{
  "five_hour": null,
  "seven_day": { "used_percentage": 18, "resets_at": 1793776498 },
  "monthly": null,
  "windows": [
    { "label": "本周", "period": "7天", "used_percentage": 18, "resets_at": 1793776498 }
  ]
}
```

成功判据：HTTP 200 **且** 解析出至少一个有效百分比窗口（FR-03.7）。`plan_type` 不参与映射；当前无需新增缓存模型字段。旧 HUD 读取主 legacy 桶，因此这次应显示“周”而非“5h”；未知周期及附加模型的动态窗口并不代表旧 HUD 已支持完整展示。

## 3. 默认安全值与失败处理

- 无测试模型／调用配置（调用未接入）；定时调用计划不可启（缺配置，FR-06）。
- 超时：connect 8s、总 12s（B）；无内建重试。
- 凭证文件：本包 App 侧仅 auth 指针（不含凭证），真凭证在 `~/.codex/auth.json`（B；目标存储见 05 第 9 节）。
- 失败仅更新 `lastAttemptAt`，不推进上次成功的 `generatedAt`；同账号有旧 legacy 桶或有效动态窗口均保留并标 `stale`。账号身份不一致不保留旧值。
- 历史缓存没有周期字段时不能可靠判断旧 5h 桶是否错标：失败时保留并标旧值，成功时以新响应完整生成 `windows` 和 legacy 桶，清掉过时投影，无需版本迁移或猜测重写。

## 4. 对接 05 调度

- 自动查询 intervalSec=60（B manifest）vs 全局 300：同 glm，S5 取舍。
- 401／403 归类 `auth`，不自行刷新登录；429 归类 `ratelimit`，由引擎执行通用退避。限频错误分类已有离线回归，实际 wham 的 429 回包形态仍待取证。
- 唤醒补一次、并发位按 05 第 5 节。
- 定时调用：调用能力未接入前计划入口标“未接入”（FR-09.4），无调度。

## 5. 业务成功判据与离线回归

1. 604800 秒主窗口、次窗口无效→仅一个周动态窗口，`five_hour=null`、`seven_day` 保留百分比及真实重置时间。
2. 标准双窗口或主次顺序交换→始终按 18000／604800 秒归类；套餐名不产生额外模块。
3. 24 小时／缺时长→显示可读周期或周期未知，不从倒计时猜周期，不写虚假 legacy 桶。
4. 同周期多个模型限额分别保留名称与身份，别名去重且空对象不遮住有效兼容数据。
5. 缺失、非法百分比不伪造 0；真实 0 正常显示；null 次窗口不补空卡。
6. 秒／毫秒／ISO／相对秒重置兼容；旧缓存同账号失败保值、切账号隔离、401／403／429／网络分类、Codex auth 不变。

运行：`node --test --test-reporter=spec scripts/test-gpt-provider.mjs`。所有用例使用临时 HOME、CLAUDE_CONFIG_DIR、CODEX_HOME 与假 curl，不读取真实凭证、不触网。

## 6. 待验证清单

| 项 | 影响 | 状态 |
| --- | --- | --- |
| wham/usage 单次真实响应 | 本次窗口映射 | 已确认本次 primary 为 604800 秒且无有效 secondary；兼容容器／附加模型仅离线验证 |
| ChatGPT 订阅经 API 的可调用路径（Codex responses/chat 端点） | 调用能力能否开放 | 待取证 |
| 多 CODEX_HOME 多实例语义 | 多账号支持 | 待核实 |
| wham 429／限流真实形态 | 05 第 5 节退避适配 | 实际回包待核实，分类已有离线回归 |
| token 过期前 refresh 窗口内读到的 access_token 可用性 | 查询失败率 | 待核实 |
| intervalSec 60 vs 全局 300 | 调度声明 | 待核实（S5） |
