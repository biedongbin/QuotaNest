# claude-code 技术｜S3 供应商包 v0.1

日期：2026-10-30。证据 B＝代码现状（`statusline.mjs`）。本包为本机数据来源，非官方余额接口。

## 1. 数据来源与"认证"

- 无网络端点、无凭证。数据入口：Claude Code statusline 机制——进程每次渲染状态行时，把 JSON 写入 statusline 脚本 stdin（B：`readStdin` 解析，上限 2MB）。
- 关键字段（B `ENV_REGISTRY['Claude-Max'].source === 'rate_limits'`）：
```json
// stdin 脱敏样例（结构按代码，值占位）
{ "rate_limits": {
    "five_hour": { "used_percentage": 47.0, "resets_at": 1779500400 },
    "seven_day": { "used_percentage": 23.0, "resets_at": 1779800400 } },
  "model": { "display_name": "Sonnet" },
  "workspace": { "current_dir": "/path" },
  "context_window": { "used_percentage": 12 } }
```
- 本包只消费 `rate_limits`；model/workspace/context_window 是 statusline 自身渲染用，不进额度快照。

## 2. 字段映射规范快照（B）

| stdin 字段 | 规范字段 | 规则 |
| --- | --- | --- |
| `rate_limits.five_hour.used_percentage` | five_hour `used_percentage` | 原义已用百分数 |
| `rate_limits.seven_day.used_percentage` | seven_day `used_percentage` | 同上 |
| `rate_limits.*.resets_at` | `resets_at`（epoch 秒） | 已是秒（B formatResetTime 按秒×1000 转 ms 计算） |

成功判据：stdin JSON 可解析且 `rate_limits` 至少一桶 `used_percentage` 有效；无 rate_limits 字段（如非订阅登录）→unknown，不报错。

## 3. 默认安全值

- 无测试模型、无调用配置（本包不代发模型请求）。
- 无超时／重试（无请求）；stdin 读取有 2MB 截断保护（B）。
- 目标数据通道：stdin → App 快照的传递方式（现有经 mjs 脚本中介写缓存 vs App 直收）**待 S5 审计定**；数据契约（字段、单位、时间精度）以本节为准。

## 4. 对接 05 调度

- **不参与自动查询调度**：无查询动作、无 due、无间隔配置；数据到达（stdin 推送）即更新快照与 `snapshotCapturedAt`。
- 快照时效：fresh/stale 阈值不能套 2×查询间隔（无查询间隔）；建议按"最近推送时间＋可配置展示阈值（如 24h 无推送标 stale）"——**待核实**合理默认值。
- 不参与定时调用调度。
- 与其他包并发无关（无请求位占用）。

## 5. 业务成功判据

1. Claude Code 会话活动→快照更新，三界面同步"已用 xx%"＋重置倒计时，标"来源：本机 Claude Code"。
2. 无会话→unknown／stale 明示，不显示 0% 或伪造时间。
3. 账号登录切换（如可判）→旧值不沿用。

## 6. 待验证清单

| 项 | 影响 | 状态 |
| --- | --- | --- |
| stdin 是否携带账号身份字段 | 换登录检测、身份关联 | 待核实 |
| `rate_limits` 缺失场景（免费/无订阅登录）的 stdin 形态 | unknown 判定 | 待核实 |
| resets_at 单位实证（秒）复确认 | 时间映射 | 低风险待复核 |
| stdin→App 快照的目标传递架构（mjs 中介 vs 直收） | 实现路径 | 待核实（S5） |
| stale 展示阈值默认值 | 时效语义 | 待核实 |
| 脱敏 fixture（stdin 样本固化） | S4 追溯 | 待固化 |
