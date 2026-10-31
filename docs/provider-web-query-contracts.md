# 内置供应商网页额度查询契约

本次实现依据公开源码和离线样本验证；没有访问真实账号，没有读取浏览器 cookie，也没有用真实凭证进行在线验证。网页或私有 Console 协议变化仍可能需要更新 adapter。

## 证据来源

公开参考仓库：[steipete/CodexBar](https://github.com/steipete/CodexBar)，固定提交 `348e2fa8d36ae8e452739ca07a79e83ab9d25e98`。本项目按下列字段契约独立实现 JavaScript 解析器，没有执行或移植上游 Swift 代码；测试 HTML/JSON 均为手工构造的脱敏数据。

- [OllamaUsageFetcher.swift](https://github.com/steipete/CodexBar/blob/348e2fa8d36ae8e452739ca07a79e83ab9d25e98/Sources/CodexBarCore/Providers/Ollama/OllamaUsageFetcher.swift#L398)：settings 地址；673–685 行为 GET、Cookie 和 HTML 请求头。
- [OllamaUsageParser.swift](https://github.com/steipete/CodexBar/blob/348e2fa8d36ae8e452739ca07a79e83ab9d25e98/Sources/CodexBarCore/Providers/Ollama/OllamaUsageParser.swift#L119)：用量区块边界、百分比和 `data-time`。
- [OllamaUsageParserTests.swift](https://github.com/steipete/CodexBar/blob/348e2fa8d36ae8e452739ca07a79e83ab9d25e98/Tests/CodexBarTests/OllamaUsageParserTests.swift#L7)：旧会话/周窗口和新月度美元用量的 HTML 样本。
- [OpenCodeGoUsageFetcher.swift](https://github.com/steipete/CodexBar/blob/348e2fa8d36ae8e452739ca07a79e83ab9d25e98/Sources/CodexBarCore/Providers/OpenCodeGo/OpenCodeGoUsageFetcher.swift#L31)：Console/legacy 路由；475–575 行为 Console Cookie、`x-org-id` 和微美分字段；605–644 行为旧 Seroval 静态字段。
- [OpenCodeGoConsoleMigrationTests.swift](https://github.com/steipete/CodexBar/blob/348e2fa8d36ae8e452739ca07a79e83ab9d25e98/Tests/CodexBarTests/OpenCodeGoConsoleMigrationTests.swift#L33)：Console JSON、旧页面和空 SPA shell 样本。
- [OpenCodeGoUsageParserTests.swift](https://github.com/steipete/CodexBar/blob/348e2fa8d36ae8e452739ca07a79e83ab9d25e98/Tests/CodexBarTests/OpenCodeGoUsageParserTests.swift#L15)：Seroval `rollingUsage`、`weeklyUsage`、`monthlyUsage`、`usagePercent`、`resetInSec`。

## Ollama

`cookieAuth` 非空时固定请求 `GET https://ollama.com/settings`，只发送 cookie 查询凭证；不会回退使用模型调用 API Key。Cookie 不存在时保留已有 `GET /api/balance` 的 Bearer API Key adapter。

HTML 区块按 `Monthly usage` / `Free usage`、`Session usage` / `Hourly usage`、`Weekly usage` 定位。只在本区块读取 `% used`、`$used of $limit used` 或 CSS `width: N%`；区块到下一个已知标签或 4000 字符为止。脚本和样式标签先移除。

重置时间仅来自本区块 `data-time` 的合法日期。缺失或非法时保持 `null`。`Hourly usage` 只进入动态窗口，不强行投影成 5 小时窗口。页面中不存在的窗口保持缺失，真实 `0%` 保留为零。

## OpenCode Go

`cookieAuth` 优先于独立查询 API Key，cookie 路线不使用模型调用凭证。

1. 可从 auth 的 `workspaceID` / `workspaceId`，或已有 `https://opencode.ai/workspace/<id>/go` / `/console/<id>/go` 查询地址确定 workspace。
2. 未配置 workspace 时，`GET https://opencode.ai/console/api/orgs`，读取数组元素的 `id`（`wrk_` / `org_`），与公开参考实现一致默认使用第一个 workspace。
3. `GET https://opencode.ai/console/api/go/status`，同时发送 Cookie 和 `x-org-id`。解析 `access.meters.fiveHour` / `week` / `month`，用 `usedMicroCents / limitMicroCents * 100` 得出使用百分比；显示金额除以 `100000000` 得到 USD。
4. 只有 legacy `auth` / `__Host-auth` cookie 才进入旧协议后备路径：Console 无法认证或没有已迁移数据时，读取公开 server-function 的 workspace 列表，再请求 `GET /workspace/<wrk_id>/go`。`/_server` 使用公开源码中的固定函数 selector 和 `X-Server-Id` / `X-Server-Instance`，没有认证密钥内置于代码。
5. 旧页面仅静态读取浅层 `rollingUsage` / `weeklyUsage` / `monthlyUsage` 中的数值 `usagePercent` / `resetInSec`。没有 `eval`、`Function` 或任意 JavaScript 执行。

每轮总预算为 18 秒。429 或网络超时不会继续尝试另一套凭证。没有 cookie 时继续使用已存在的 `/zen/go/v1/usage` Bearer adapter。

重置只接受明确 `resetsAt` / `reset_at`，或明确相对秒 `resetInSec`。没有 meter 重置字段时保持未知；即使 Console 返回 `access.endsAt`，也不会将该账期结束时间代填成额度重置时间。明确百分比 `0.5` 保持 `0.5%`，不猜测为小数比例 `50%`。

## 离线验证

```sh
node scripts/test-provider-web-parsing.mjs
node scripts/test-account-query-providers.mjs
```

测试用本地假 curl 代替所有 HTTP 调用，覆盖 HTML/Seroval/Console JSON、Cookie 优先、0%、缺失窗口、缺失重置时间、登录失效页面和登录跳转、旧协议回退以及 App 模式下不写缓存。样本证明解析契约与传输参数，不等价于真实账号在线验收。
