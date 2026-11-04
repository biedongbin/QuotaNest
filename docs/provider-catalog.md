# 供应商认证与额度能力目录

本次最终验证：261 项 Swift 测试／31 个 suite 通过；9 类实际 wrapper／fake-cURL 适配器回归全部通过；另有 36 项账号失败隔离回归、30 项自定义查询契约场景及既有查询／HUD 回归通过，Release 构建成功。各脚本使用不同计数口径，不将检查点与 TAP tests 混加为一个总数。日志保留在 `.build/provider-catalog-tests.log`、`.build/test-catalog-*-final.log` 与 `.build/provider-catalog-release.log`。本次未使用真实凭证、未发起真实模型调用，供应商当前服务可用性、账号权限和真实窗口变化仍需实号验证。

本目录合并固定源码研究与当前TokenHUD资源状态。主表72个候选中，**55个已实现查询适配，17个不启用**；其中22个声明模型调用端点，33个仅查询。实现表示manifest与查询适配资源存在，不等于真实账号联通、模型套餐归属或动态开窗机制已验证。保留原有 `gpt`、`glm`、`cline`、`ollama`、`opencode-go` 五个slug。

新用户目标输入只有供应商类型及基础 API Key，或既有 Auth 文件路径。查询必须继承同一基础认证。外部授权文件只读，失效时由原 CLI/持有者更新后重读；不增加查询专用 Key、Cookie 或 Token 输入区。不同产品/独立认证域使用独立类型，品牌在本目录归组；Auth自带的region/base随同身份读取，不新增查询配置。未知值不显示成零或无限，余额不显示成虚构周期百分比，套餐到期不自动解释为额度重置。

## 来源与范围

| 代号 | 固定源码版本 | 许可与范围 |
|---|---|---|
| M | Magpie `v0.1.2183`，`0414bbeddbfc2028508b610fd1e7c194143454a0` | [MIT](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/LICENSE#L1-L21)，2026 yetone；原生实现、插件宿主与迁移证据 |
| N | 9router `0.5.99`，`1066c36281a040a563611bca0dbe2e6f6f8b17a3` | [MIT](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/LICENSE#L1-L21)，2024–2026 decolua and contributors；usage/registry源码 |
| C | CLIProxyAPI `01b24f1f95dc9b309765212c52b25b25e005ff01` | [MIT](https://github.com/router-for-me/CLIProxyAPI/blob/01b24f1f95dc9b309765212c52b25b25e005ff01/LICENSE#L1-L14)；认证格式与管理代理 |
| U | CPA官方管理端 `f154fa9380825c4fe94bc577a9abaa7e505f8875` | [MIT](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/LICENSE#L1-L13)；真实quota请求与解析 |
| P | Magpie官方community plugins `3e24e228377ed17a9e5991c4e715dfde0244a1ea` | [MIT](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/LICENSE#L1-L21)，2026 magpie-community contributors；11个迁移包及额外usage实现，本轮新增静态证据 |

研究日期：2026-11-04。只转述接口事实与字段，不大段复制版权实现；若后续复制实质代码，须保留对应版权和许可。N 本地已有用户修改，本文的usage/registry证据不在其已修改文件列表中；OAuth周边仍需按固定提交复核，不把本地修改冒充上游事实。全部为静态取证，未请求供应商、读取实际凭证、运行插件或刷新Token。开放插件市场不可能由固定快照穷尽。

M 的查询入口有订阅、Key套餐和余额三条，见[聚合器](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/quotas.go#L51-L71)。N 的133项启用registry中仅28项有usage分派，`iflow`只有固定文案；27项有真实请求，其中Groq只解析速率头，MiMo需要额外账号会话，不能把133项算成可查额度。[N分派器](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage.js#L39-L88)。U 的原生quota只有Antigravity、Claude、Codex、Devin、Kimi、Meta、xAI七家，通用plugin adapter不是第八家。[U注册表](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/src/features/quota/providers/index.ts#L54-L65)。

## 合并后的真实查询清单

providerID为稳定类型标识。主表按唯一ID计数，区域/产品分列；ZCode个人Coding复用 `glm` / `zai-coding`，Start/gift另列 `zcode-start`。集成状态由实际manifest核对；查询和模型调用分开标记。认证列表示当前可用于额度查询的模式，上游研究支持的其它认证格式不自动进入选择器。

分类：**直接Key/Authfile只读（优先）**＝同一基础认证的查询可提取；**同源派生（可实施）**＝token交换/签名/私有协议来源相同，但需适配，旧行“进阶”同此义；**需要外部权限/账号第二凭证（不启用）**＝不能仅凭基础Key/Auth完成查询；**无真实额度（不启用）**＝仅登录/套餐/模型目录。**待裁决**保留来源冲突，裁决前不进入额度选择器。分类保留上游协议与复杂度证据；当前实现状态独立列出。来源中的待裁决项，若本轮已选定实现，以下方本地资源说明为准。

| providerID | 集成状态 | 品牌 / 独立区域类型 | 基础认证 | 真实查询能力 / 窗口 | 分类与限制 | 固定源码证据 |
|---|---|---|---|---|---|---|
| `claude-code` | 已实现·仅查询 | Claude Code订阅 | Auth文件 | OAuth usage：5h、周/模型周、extra usage；M改走CLI `/usage`及响应事件 | 直接（CPA JSON）；原生Keychain/CLI为进阶；两条协议路径需明确选择 | [U usage](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/src/features/quota/providers/claude/data.ts#L50-L127)、[M CLI策略](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/subscription_usage.go#L649-L653) |
| `gpt` | 已实现·查询+模型调用 | Codex / ChatGPT订阅 | Auth文件 | WHAM使用量、实际duration窗口、review/额外窗口、credits | 直接；普通OpenAI Key不等价；SIWC-only待研究 | [M窗口](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/subscription_usage.go#L990-L1067)、[U解析](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/src/features/quota/providers/codex/data.ts#L66-L186) |
| `github-copilot` | 已实现·仅查询 | GitHub Copilot | Auth文件 | chat/completions/premium月额度 | 进阶：同GitHub OAuth换模型token；P支持premium credits/requests与GHE，不是普通PAT | [M查询](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/subscription_usage.go#L1155-L1261)、[N查询](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/github.js#L15-L99)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/copilot/index.mjs#L32) |
| `gemini-cli` | 已实现·仅查询 | Gemini CLI | Auth文件 | retrieveUserQuota模型桶剩余比例/reset | 进阶：project发现、Code Assist套餐/scope；不硬编码5h | [M来源](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/google.go#L117-L143)、[N请求](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/google.js#L22-L114) |
| `antigravity` | 已实现·仅查询 | Google Antigravity | Auth文件 | summary共享池5h/weekly；模型quotaInfo | 直接（完整CPA JSON）；缺project与本机IDE导入为进阶，M无IDE自动导入 | [U请求](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/src/features/quota/providers/antigravity/data.ts#L119-L181)、[M来源边界](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/google.go#L143-L224) |
| `glm` | 已实现·查询+模型调用 | 智谱 GLM Coding中国 | API Key | quota/limit：小时、周、MCP月窗 | 直接个人；P ZCode personal即本类型，不新建zcode-personal；usage裸Authorization、模型同Key Anthropic；团队另论 | [M分派/解析](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/planquota.go#L37-L140)、[N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/glm.js#L19-L95)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/zcode/index.mjs#L488) |
| `zai-coding` | 已实现·查询+模型调用 | Z.ai GLM Coding国际 | API Key | 同上，独立api.z.ai域 | 直接个人；P ZCode国际personal即本类型，同Key查询/Anthropic，不重复计数 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/planquota.go#L47-L50)、[N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/providers/registry/glm.js#L37-L62)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/zcode/index.mjs#L488) |
| `minimax-coding-cn` | 已实现·查询+模型调用 | MiniMax Token/Coding中国 | API Key | interval/weekly，general模型池及独立video等池 | 直接；多端点计数方向不同，见冲突节 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/planquota.go#L226-L347)、[N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/minimax.js#L53-L226) |
| `minimax-coding` | 已实现·查询+模型调用 | MiniMax Token/Coding国际 | API Key | 同上，国际域 | 直接；PAYG Key无套餐不造卡 | [M host](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/planquota.go#L60-L66)、[N host](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/providers/registry/minimax.js#L18-L54) |
| `minimax-code-cn` | 已实现·仅查询 | MiniMax Code账号中国 | Auth文件 | membership credits + token_plan interval/weekly | 同源派生：同账号AT、MD5客户端签名、workspace/group；P补齐M Plan/credits批次到期 | [N协议](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/minimaxCodeUsage.js#L10-L244)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/minimax/index.mjs#L1053) |
| `minimax-code` | 已实现·仅查询 | MiniMax Code账号国际 | Auth文件 | 同上，国际账号域 | 同源派生：同账号AT，国际域与中国不互试；M Plan与credits分池 | [N国际模型域](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/providers/registry/minimax-code-global.js#L23-L33)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/minimax/index.mjs#L1053) |
| `kimi-code-cn` | 已实现·查询+模型调用 | Kimi Code中国 .com | API Key | coding usages：5h/周/月，按返回duration和字段 | 直接；OAuth保留device身份，和Moonshot余额分开 | [M解析](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/planquota.go#L400-L568)、[U域](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/src/services/api/kimiQuota.ts#L24-L121) |
| `kimi-code` | 已实现·查询+模型调用 | Kimi Code国际 .ai | API Key | 同上，独立认证域 | 直接；不跨域试Token | [C schema](https://github.com/router-for-me/CLIProxyAPI/blob/01b24f1f95dc9b309765212c52b25b25e005ff01/internal/auth/kimi/token.go#L17-L40)、[M域](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/presets.go#L210-L215) |
| `moonshot-cn` | 已实现·查询+模型调用 | Moonshot Kimi API中国 | API Key | available_balance，CNY | 直接余额，无reset | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L60-L63) |
| `moonshot` | 已实现·查询+模型调用 | Moonshot Kimi API国际 | API Key | available_balance，USD | 直接余额，无reset | [M解析](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L414-L430) |
| `codebuddy-cn` | 已实现·查询+模型调用 | CodeBuddy中国 | API Key | recurring/bonus包credit容量与周期 | 直接协议；外部Auth来源格式待定义 | [N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/codebuddy-cn.js#L46-L145) |
| `codebuddy` | 已实现·查询+模型调用 | CodeBuddy国际 | API Key | 同上，国际域 | 直接协议；不是腾讯企业云AKSK套餐 | [N域](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/providers/registry/codebuddy-intl.js#L24-L43) |
| `qoder` | 已实现·仅查询 | Qoder国际 | Auth文件 | userQuota、orgResourcePackage credits与到期 | 同源派生：device→job同登录链；PAT换job可同时查usage；LLM需COSY协议，无额外Cookie | [N请求](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/misc.js#L230-L289)、[派生](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/qoderModels.js#L70-L101)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/qoder/index.mjs#L3179) |
| `qoder-cn` | 已实现·仅查询 | Qoder中国 | Auth文件 | 同上，openapi.qoder.com.cn | 同源派生：独立中国域/PAT交换；Lingma专域导入无usage证据，不与公共Qoder混用 | [N地区常量](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/shared/qoder/constants.js#L22-L99)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/qoder/index.mjs#L3179) |
| `kiro` | 已实现·仅查询 | Kiro | Auth文件 | GetUsageLimits credits、trial、reset | 同源派生：同OAuth或ksk_Key；profile/region与AWS eventstream推理；不照搬刷新写回外部文件 | [N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/kiro.js#L12-L175)、[M退役](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/AGENTS.md#L25-L87)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/kiro/index.mjs#L321) |
| `grok-cli` | 已实现·仅查询 | Grok CLI / Grok Build OAuth | Auth文件 | billing周/月、花费/预付credits；gRPC回退 | 同源派生：P读~/.grok/auth.json同key；真实Responses；插件续期运行grok models会写外部Auth，不执行 | [U](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/src/features/quota/providers/xai/data.ts#L42-L101)、[N gRPC](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/grok-cli.js#L305-L420)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/grok/index.mjs#L818) |
| `devin` | 已实现·仅查询 | Devin CLI | Auth文件 | GetUserStatus日/周剩余百分比 | 查询直接、完整接入同源派生：CLI windsurf_api_key/session；usage body认证，LLM为Basic raw-key+Connect protobuf | [C格式](https://github.com/router-for-me/CLIProxyAPI/blob/01b24f1f95dc9b309765212c52b25b25e005ff01/internal/auth/devin/record.go#L68-L90)、[U请求](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/src/features/quota/providers/devin/requests.ts#L77-L102)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/devin/index.mjs#L2986) |
| `zed` | 已实现·仅查询 | Zed | Auth文件 | N称edit_predictions/model_requests；P仅套餐/账期、无真实额度计数 | 已按N字段实现查询；响应缺数值只展示未知/套餐；无原生Keychain导入，不以/models当quota | [N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/zed.js#L116-L212)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/zed/index.mjs#L1201) |
| `deepseek` | 已实现·查询+模型调用 | DeepSeek | API Key | 多币种total/granted/topped-up余额 | 直接；无reset | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L317-L362)、[N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/deepseek.js#L9-L109) |
| `openrouter` | 已实现·查询+模型调用 | OpenRouter | API Key | total_credits−total_usage，USD | 直接；N无handler不否定M正向实现 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L64-L65)、[解析](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L433-L450) |
| `commandcode` | 已实现·查询+模型调用 | Command Code | API Key | 5h/周、month credits、purchased/free余额 | 直接非Go：同apiKey；Go完整模型调用需/alpha/generate适配；按计划区分credits与USD | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/commandcode_plan.go#L152-L298)、[N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/commandcode.js#L9-L130)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/commandcode/index.mjs#L706) |
| `ollama` | 已实现·查询+模型调用 | Ollama Cloud | API Key | M included/purchased USD与legacy session/weekly；N rate usage | 直接余额；套餐展示按实际响应，paid reset可能未知 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/ollama_usage.go#L15-L157)、[N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/misc.js#L58-L140) |
| `opencode-go` | 已实现·查询+模型调用 | OpenCode Go | API Key | rolling/weekly/monthly百分比与reset | 已从实际源码提取URL并实现；workspace/member绑定，查询套餐窗口 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/planquota.go#L40-L44)、[N URL](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/providers/registry/opencode-go.js#L24-L25) |
| `opencode-zen` | 已实现·查询+模型调用 | OpenCode Zen | API Key | N有rolling/weekly/monthly查询，M称Key无余额API | 已实现套餐窗口；不承诺PAYG现金余额，缺billing/entitlement明确失败 | [N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/opencode-zen.js#L25-L103)、[M否定范围](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L1352-L1360) |
| `cline` | 已实现·查询+模型调用 | Cline / ClinePass | API Key | 5h/周/月percentUsed + balance微美元 | 直接；无套餐404仍可读余额；N未支持不否定M | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/cline_usage.go#L24-L155) |
| `aihubmix` | 已实现·查询+模型调用 | AiHubMix | API Key | 受限Key剩余USD | 直接受限Key；无限额Key账户余额需独立token，不启用该扩展 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L511-L570) |
| `stepfun-cn` | 已实现·查询+模型调用 | StepFun API中国 | API Key | accounts.balance CNY，含券 | 直接余额；和网页Step Plan窗口分开 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L70-L73)、[解析](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L490-L508) |
| `stepfun` | 已实现·查询+模型调用 | StepFun API国际 | API Key | 同上USD | 直接余额 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L70-L73) |
| `vercel-ai-gateway` | 已实现·查询+模型调用 | Vercel AI Gateway | API Key | credits.balance / total_used USD | 直接余额；不要照搬人工$5上限 | [N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/misc.js#L161-L224) |
| `groq` | 不启用 | Groq | API Key | models响应的requests/tokens速率头 | 无真实额度：仅速率头，不满足额度供应商纳入要求 | [N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/groq.js#L22-L129) |
| `stepfun-plan-cn` | 不启用 | StepFun Step Plan中国 | APIKey不能查询该窗口；另需网页session | 5h/周/credits | 不启用：Oasis cookie与推理Key不同认证 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/stepfun_plan.go#L3-L23) |
| `stepfun-plan` | 不启用 | StepFun Step Plan国际 | 同上，独立国际网页session | 同上 | 不启用同一原因 | [M域](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/stepfun_plan.go#L45-L49) |
| `volcengine-coding` | 不启用 | Volcengine Ark Coding Plan | 推理APIKey另需云AK/SK | 5h/周/月控制面usage | 不启用当前两认证简化流程；IAM与第二凭证 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/volcengine_usage.go#L3-L17) |
| `volcengine-agent` | 不启用 | Volcengine Ark Agent Plan | 同上 | AFP 5h/周/月 | 不启用；字段来自其它工具，源码未实见响应 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/volcengine_usage.go#L329-L377) |
| `tencent-plan-cn` | 不启用 | Tencent TokenHub企业中国 | 推理Key另需SecretId/SecretKey | 周期credits/tokens | 不启用；云CAM签名认证，源码未实测 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/tencent_usage.go#L3-L22) |
| `tencent-plan` | 不启用 | Tencent TokenHub企业国际 | 同上，Singapore | 同上 | 不启用；与CodeBuddy国际不是同一协议 | [M域](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/tencent_usage.go#L68-L88) |
| `xiaomi-mimo-desktop` | 已实现·仅查询 | Xiaomi MiMo Desktop | Auth文件 | app每周剩余比例/reset；同身份可派生Token Plan但两池分开 | 同源派生：完整Xiaomi Auth派生app Cookie同时用于usage/LLM；独立sk/tp-Key不足；仅已有导出Auth，无原生app importer | [N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/xiaomi-mimo.js#L22-L70)、[SSO](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/shared/mimoAccount.js#L166-L237)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/mimo/index.mjs#L537) |
| `meta-muse` | 不启用 | Meta Muse Code | Auth文件dca_token（不是派生LLM api_key） | subs_usage短窗/weekly | 不启用：POST key接口兼mint key，副作用待确认 | [U请求](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/src/features/quota/providers/meta/requests.ts#L80-L116)、[C MintedKeyResponse](https://github.com/router-for-me/CLIProxyAPI/blob/01b24f1f95dc9b309765212c52b25b25e005ff01/internal/auth/meta/meta.go#L67-L104) |
| `siliconflow-cn` | 不启用 | SiliconFlow中国 | APIKey | 历史data.totalBalance | 不启用：余额端点已410退役，非现行可用能力 | [M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L452-L486) |
| `siliconflow` | 不启用 | SiliconFlow国际 | APIKey | 同上 | 不启用：同上 | [M区域](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L66-L69) |
| `cursor` | 已实现·仅查询 | Cursor | Auth文件 | 当前period pool、team/on-demand USD、grants；Bot池仅旁注 | 同源派生：同JWT合成dashboard Cookie；Connect双向protobuf模型；team须匹配 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/cursor/index.mjs#L3559) |
| `factory` | 已实现·仅查询 | Factory / Droid | API Key | Standard/Core 5h/7d/30d百分比、extra cents余额 | 直接Key优先；模型需Droid headers/preamble；OAuth派生复杂，无原生Droid importer证据 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/factory/index.mjs#L1931) |
| `workbuddy-cn` | 已实现·仅查询 | WorkBuddy中国 | Auth文件 | credits周期包/预付余额/到期；无固定5h推定 | 同源派生；Key usage未知；5.6+加密原生token本源码不能解 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/workbuddy/index.mjs#L3839) |
| `workbuddy` | 已实现·仅查询 | WorkBuddy AI国际 | Auth文件 | 同上，www.workbuddy.ai独立域 | 同源派生；Key不支持真实usage；国际Messages未证实 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/workbuddy/index.mjs#L3839) |
| `zcode-start` | 已实现·仅查询 | ZCode Start / gift | Auth文件 | gift balance按模型桶/active与pending、到期 | 同源派生：同JWT查gift/调用gift Anthropic；不借Coding Key访问gift；禁用自动领取/建Key | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/zcode/index.mjs#L583) |
| `joycode` | 已实现·仅查询 | JoyCode / 京东 | Auth文件 | usageItems各桶used/total/remain/unit，plan到期 | 同源派生：HMAC query与ptkey headers；未证明refresh，过期原持有者重登 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/joycode/index.mjs#L644) |
| `trae-cn` | 已实现·仅查询 | Trae中国 | Auth文件 | ide_user_ent_usage credits、到期 | 同源派生：同账号token，私有聊天；不执行refresh/签到 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/trae/index.mjs#L123) |
| `trae` | 已实现·仅查询 | Trae国际 | Auth文件 | user_current_entitlement_list美元池、SG/US域 | 同源派生：按Auth区域路由，同token查询/模型；无额外Cookie | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/trae/index.mjs#L215) |
| `agnes-code` | 已实现·仅查询 | Agnes Code桌面 | API Key / Auth文件 | total/time_sensitive/permanent积分余额，无reset | 直接Authfile优先：同token标准chat；原生加密来源reader另实现，不能与国际Agnes合并 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/agnes-code/index.mjs#L421) |
| `catpaw` | 已实现·仅查询 | 美团妙手CatPaw | Auth文件 | catx credit balance；仅积分余额 | 查询直接Authfile；完整模型同源派生round/event/turn；X-Auth-Token与Cookie携同token | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/catpaw/index.mjs#L945) |
| `loomy` | 已实现·仅查询 | 讯飞Loomy | Auth文件 | 每日/永久credits；有limit/remaining才算日窗，北京午夜 | 直接Authfile查询；同session token+Bearer；需修正上游used/amount语义，不能照搬 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/loomy/index.mjs#L480) |
| `raccoon` | 已实现·仅查询 | 商汤小浣熊 | Auth文件 | points余额、entitlement、grant bills到期；有完整grant才造比例 | 同源派生：同AT；原生路径/refresh复杂，过期由原客户端更新 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/raccoon/index.mjs#L632) |
| `autoclaw-cn` | 已实现·仅查询 | AutoClaw中国 | Auth文件 | wallets total_balance/分池，zhipuai.cn域 | 同源派生：Bearer+客户端签名；只迁余额，禁用自动签到和峰值账本伪窗口 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/autoclaw/index.mjs#L1002) |
| `autoclaw` | 已实现·仅查询 | AutoClaw国际 | Auth文件 | wallets total_balance/分池，autoglm.ai域 | 同源派生：同token查询/模型；无服务端固定窗口，不复制签到副作用 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/autoclaw/index.mjs#L1002) |
| `codearts` | 已实现·仅查询 | 华为CodeArts码道 | Auth文件 | statistics/benefit/batches积分桶与到期 | 同源派生：基础临时credential同时签名模型/查询；不同于平台模型Key另加云AKSK | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/codearts/index.mjs#L2808) |
| `officeace` | 已实现·仅查询 | 华为OfficeAce / AgentArts | Auth文件 | subscription skus/bonus积分桶；trial无到期 | 同源派生：同credential模型/查询；trial与bucket expiry不冒充可重置 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/codearts/index.mjs#L4190) |
| `qwenwork` | 已实现·仅查询 | 千问办公公有云 | Auth文件 | account-context quota + personal daily/monthly/longterm wallets | 同源派生：同device token即chat token；COSY私有协议；无PAT交换 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/qoder/index.mjs#L2873) |
| `qwenwork-enterprise` | 已实现·仅查询 | 千问办公企业旗舰 | Auth文件 | 企业account-context credits/plan；不套公共个人wallet | 同源派生：企业host来自基础Auth，缺host明确失败；不添加查询URL/第二凭据 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/qoder/index.mjs#L2935) |
| `orcaterm` | 已实现·仅查询 | 腾讯云OrcaTerm遨驰 | Auth文件 | DescribeUserBillingStatus AI Q&A questions周期used/limit | 同源派生：CAPI签名/cookie携同token、私有模型协议；非云SecretKey套餐 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/orcaterm/index.mjs#L2255) |
| `cloudflare-workers-ai` | 已实现·仅查询 | Cloudflare Workers AI | Auth文件 / API Key | GraphQL今日totalNeurons，UTC日窗；10k免费额 | 同源派生条件：同token需Analytics权限及accountId；不可读时unknown，不把回退额度当实测 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/cloudflare-workers-ai/src/index.mjs#L369) |
| `agnes` | 不启用 | Agnes AI国际 | 模型APIKey另需consoleToken | Token/Agent Plan及USD wallet | 需要账号第二凭证，不启用；同JSON容纳两token不等于同认证 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/agnes/index.mjs#L138) |
| `astudio` | 不启用 | 讯飞AStudio | 模型bearer另需session.token/accountId | 真实通用/星火积分与会员；单Key只/models | 需要账号第二凭证，不启用；模型连通不算quota | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/astudio/index.mjs#L472) |
| `sensenova-token-plan` | 不启用 | 商汤日日新SenseNova Token Plan | 模型APIKey另需console OAuth | pool-usage 5h/7d/赠金到期 | 需要账号第二凭证，不启用；不能用apiKey替代console JWT | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/sensenova/index.mjs#L656) |
| `gcp-ai` | 不启用 | GCP Vertex促销赠金 | 模型gcloud/ADC另需Console浏览器session | 渲染表的USD/JPY promotional credits | 需要外部浏览器权限/第二会话，不启用；ADC不能推出Console session | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/gcp-ai/index.mjs#L217) |
| `kimi-work` | 不启用 | Kimi桌面Work会员 | Work key另需会员webToken | GetSubscriptionStats月共享池/Code占比 | 需要账号第二凭证，不启用；同文件配对不证明Work key可读会员 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/kimi-work/index.mjs#L641) |
| `opendesign` | 不启用 | Open Design Design Plan | 推理APIKey另需账户controlKey | workspace billing preflight/summary，5h/7d/USD wallet | 需要控制面账户凭据；Key-only无usage，不启用，待证明可由基础Auth派生 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/opendesign/index.mjs#L390) |
| `river` | 不启用 | River | APIKey | /v1/models仅验key，plan=Pay as you go，无余额/窗口 | 无真实额度，不启用；可调用模型不能算usage查询 | [P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/river/index.mjs#L185) |
## Auth文件与独立请求细节

源项目的连接记录、CPA管理代理和Magpie宿主均不是TokenHUD必须依赖的运行时。CPA `$TOKEN$`是内部替换符；独立适配应从基础Auth读实际值，不需要auth_index、管理Key或CPA端口。[C代理替换](https://github.com/router-for-me/CLIProxyAPI/blob/01b24f1f95dc9b309765212c52b25b25e005ff01/internal/api/handlers/management/api_tools.go#L149-L188)。N常见标准连接字段是accessToken/apiKey/providerSpecificData，不能把它当每家CLI原生JSON格式。

| 类型 | Auth路径 / JSON字段 | 查询方法、认证与数据单位 |
|---|---|---|
| Claude Code | 原生默认`~/.claude/.credentials.json`，`claudeAiOauth.accessToken`；macOS常在Keychain。CPA明确文件根`access_token`，默认目录`~/.cli-proxy-api`有多账号文件 | U GET `https://api.anthropic.com/api/oauth/usage`，Bearer + anthropic-beta oauth-2025-04-20 + CLI UA；utilization为已用%；resets_at绝对时间。M则运行CLI `/usage`，响应事件reset为epoch秒。[C格式](https://github.com/router-for-me/CLIProxyAPI/blob/01b24f1f95dc9b309765212c52b25b25e005ff01/internal/auth/claude/token.go#L20-L51)、[M格式](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/account.go#L393-L410) |
| Codex | `$CODEX_HOME/auth.json`或`~/.codex/auth.json`，`tokens.access_token`、`tokens.account_id`；CPA根access_token/account_id | GET `https://chatgpt.com/backend-api/wham/usage`，Bearer +可选/账号需要的chatgpt-account-id；used_percent为百分比；reset_at epoch秒、reset_after_seconds/limit_window_seconds为秒。[M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/subscription_usage.go#L1128-L1151) |
| Copilot | `~/.config/github-copilot/apps.json/hosts.json`条目oauth_token；CLI `~/.copilot/config.json`的copilotTokens，或Keychain | GET `https://api.github.com/copilot_internal/user`，**Authorization: token**（非Bearer）；quota_reset_at epoch秒，顶层日期ISO/UTC日期；月度额度。[M来源](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/copilot_cli.go#L48-L157) |
| Gemini CLI | `~/.gemini/oauth_creds.json`，access_token/refresh_token/expiry_date；expiry_date毫秒 | POST `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`，Bearer JSON `{project}`；remainingFraction为0..1剩余，resetTime RFC3339；可能先loadCodeAssist。[M](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/google.go#L1128-L1162) |
| Antigravity | CPA文件根access_token/project_id；M保存logins的googleAuth，不自动导入IDE | POST `https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`，Bearer JSON `{project}`，Antigravity UA；window=5h/weekly，remainingFraction与resetTime RFC3339。[U](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/src/utils/quota/constants.ts#L67-L98) |
| Kimi Code | CPA根access_token/domain/type/device_id；Key模式直接基础APIKey | GET `https://api.kimi.com/coding/v1/usages`或`.ai`，OAuth Bearer；Key在M用Bearer，在N用x-api-key。reset支持RFC3339/epoch秒/毫秒；used_ratio×100。[N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/kimi.js#L103-L205) |
| GLM个人 | 基础APIKey | GET各区域`/api/monitor/usage/quota/limit`；M裸Authorization，N Bearer；data.limits[].percentage；nextResetTime毫秒，unit3小时/unit6周。团队另有Bigmodel-Organization/Project。[M团队](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/planquota.go#L871-L924) |
| MiniMax平台Key | 基础APIKey，与Code账号AT分开 | M GET各API host `/v1/token_plan/remains`；N有www/api openplatform回退。Bearer；remaining_percent为剩余；epoch秒/毫秒，interval长度按start/end。不同URL usage_count语义不可共用。[N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/minimax.js#L53-L226) |
| Devin CLI | CPA根api_key/session_token，明确属于Devin会话 | POST `https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus`，Connect-Protocol-Version:1；token放body.metadata.apiKey；daily/weekly剩余%，reset Unix秒。[U](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/src/services/api/devinQuota.ts#L33-L67) |
| Zed | 导出Auth含accessToken/userId/systemId；N有Keychain线索，P未实现原生导入 | GET `https://cloud.zed.dev/client/users/me`；Authorization=`<userId> <token>`；N解析usage次数，P仅plan/subscription_period.ended_at，当前按N实现查询，缺数值保持未知。[N认证](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/shared/zedAuth.js#L176-L231)、[P plan-only](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/zed/index.mjs#L1201) |
| Grok OAuth | CPA根access_token；P原生`${GROK_HOME:-~/.grok}/auth.json`按scope对象读key/expires_at | GET `https://cli-chat-proxy.grok.com/v1/billing?format=credits`；P usage仅Bearer+Accept，模型另带CLI headers；按source版本匹配period/unit，P的onDemand.val未证实USD，U金额按cents。禁用grok models自动续期写外部Auth。[U解析](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/src/utils/quota/builders.ts#L474-L565)、[P请求](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/grok/index.mjs#L818) |
| Kiro | IDE `~/.aws/sso/cache/kiro-auth-token.json`含accessToken/refreshToken/region/profileArn；CLI macOS `~/Library/Application Support/kiro-cli/data.sqlite3`，不能伪称JSON | P Auth GET management.region.kiro.dev/Get-Usage-Limits；ksk_Key POST根路径+X-Amz-Target GetUsageLimits、tokentype API_KEY、body.origin KIRO_CLI；均同Bearer，credits/reset秒。模型为AWS eventstream；禁复制原生刷新写回。[N](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/kiro.js#L12-L175)、[P](https://github.com/magpie-community/plugins/blob/3e24e228377ed17a9e5991c4e715dfde0244a1ea/packages/kiro/index.mjs#L321) |

余额固定接口：DeepSeek `GET https://api.deepseek.com/user/balance`；Moonshot各域`GET /v1/users/me/balance`；OpenRouter `GET https://openrouter.ai/api/v1/credits`；StepFun各域`GET /v1/accounts`；AiHubMix `GET https://aihubmix.com/dashboard/billing/remain`。均继承基础Key，通常Bearer。[M host白名单](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L46-L90)。Cline另需GET用户身份再GET用户balance，微美元除1e6。[M Cline](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/cline_usage.go#L97-L155)。

## 来源差异与当前实现边界

| 主题 | 源码差异 | 当前处理与后续限制 |
|---|---|---|
| Claude | M明确不直接请求Anthropic，依赖CLI；N/U直接OAuth usage，N还加cedar_ember查询参数 | 明确支持CPA/原生Auth的直接协议，还是依赖CLI；不把M策略当上游API不存在的证据 |
| GLM / Kimi Key header | M GLM裸Key、N Bearer；M Kimi Bearer、N x-api-key | 本轮GLM已选裸Authorization并有离线请求回归；其它类型按各自适配，不跨域试Token |
| OpenCode Zen | N有usage窗口查询；M明确不提供PAYG Key余额；早期研究URL遮罩已由实际源码提取消除 | 本轮已提取源码真实URL并实现套餐窗口；PAYG现金余额仍无承诺，来源差异不合并成一个余额结论 |
| MiniMax | M token_plan与N coding_plan的usage_count方向不同，N按URL区分；M按percent校验计数 | 优先服务端remaining_percent，计数按选中端点转换；零total不等于零额度 |
| Ollama | M `/api/balance`金额、period/legacy窗；N `/api/usage`比例，paid reset缺失 | 可保留两个能力但不能拼造同一上限；N free reset是注册日估算，不是服务端确认 |
| Command Code | M金额USD表示；N称credits，另带orgId并用本地plan表推导cap | 不先承诺货币或总额；保留原字段，确认组织作用域与单位后决定展示 |
| Grok | JSON与gRPC路径、客户端版本、金额单位不同 | 避免旧UA 426；cents/credits按实际响应匹配，不能统一当USD |
| 缺项目/过期Auth | N/C等包装会刷新并落盘，Google project发现可能onboard | TokenHUD fetch不得顺手刷新、写外部授权或onboard；只读基础路径先明确缺失状态 |

## Community插件补证与去重结果

P已完成固定SHA静态研究，31个包有已识别usage hook（CodeArts包含CodeArts/OfficeAce两个；Qoder另含QwenWork变体）。hook数量不是独立品牌数，更不是可直接集成数。上表已吸收真实新provider，重复的Command Code、Devin、Grok、Kiro、Qoder、Zed、Copilot、Cline、MiniMax Code只补证，ZCode个人Coding复用`glm`/`zai-coding`，保留`zcode-start`区分gift池。

P的请求method/header/body、多请求流程、来源字段、模型协议、单位/reset与副作用已归入上表固定GitHub证据。当前实现能力以本地manifest为准；不引用临时研究文件作为长期依赖。

| 容易误判的能力 | 目录裁定 |
|---|---|
| Cookie传输 | Cursor dashboard Cookie由同JWT合成，CatPaw模型Cookie携同余额token，MiMo app Cookie由同passToken派生；均不因Cookie字样判第二认证。 |
| 同一JSON | Agnes、AStudio、SenseNova、Kimi Work即使把模型Key和console/member token放同一文件，仍是两凭据；不增查询认证UI。 |
| 原生Auth默认来源 | P没有Factory Droid、MiMo app、公共Qoder、Zed的现有原生文件/Keychain reader证据；已有host导出Auth可另写reader，不能声称TokenHUD已自动读取客户端。 |
| WorkBuddy | 5.6+加密accessToken本源码不能解；已有有效明文/host Auth才可实施。APIKey usage明确unknown。 |
| Zed | N有计数parser，P同端点只返回plan/period；按N计数字段实现查询；缺字段保持未知，不拿model token或/models算余额。 |
| 私有模型协议 | Cursor双向Connect/protobuf、Devin Connect、Kiro AWS eventstream、Qoder COSY、Zed/completions包装均需真实适配；SDK facade URL不是厂商标准接口。 |
| 副作用 | Kiro刷新会写原生SQLite/JSON，Grok/Cursor调用CLI会刷新外部文件，ZCode团队helper可能创建Key，AutoClaw可自动签到/写峰值账本；本轮只提取只读来源和查询，禁照搬这些动作。 |

TokenHUD是Swift+Node provider脚本架构。**装npm插件不会自动集成**：应提取只读credential reader、独立request/parser与必要模型协议到各provider，并将固定地址/协议写manifest。P依赖的宿主auth.set、跨进程refresh锁、账本和代理不是TokenHUD已实现能力。原11迁移证据见[M官方说明](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/AGENTS.md#L25-L98)。

## 自定义供应商：仅API Key

自定义OpenAI兼容、Anthropic兼容两种调用协议继续保留，作为用户提供真实接口的通用入口，不计入55个固定供应商类型。两者仅使用基础API Key，不提供自定义Auth模式或独立查询凭证。用户设置基础调用地址、实际模型及完整额度查询URL；默认额度请求为HTTP GET、继承同一Key，返回标准JSON后通过通用normalize解析（支持data包装、真实windows/余额字段）。不猜测billing路径、不要求自写脚本；没有真实额度接口的品牌不加入内置额度选择器。仅速率头、Key验证或模型连通不算额度查询。

## 通用中继能力

| 类型 | 已证实协议 | 当前结论 |
|---|---|---|
| new-api / one-api | 用户中继host `/api/usage/token`，同Key，data.total_available/500000 | 进阶：不是固定品牌host；账号`/api/user/self`需另access token与New-Api-User，不启用独立查询认证 |
| sub2api | Key usage返回remaining或rate_limits：5h/1d/7d used/limit/reset_at | 进阶：URL尾部受工具遮罩，先核对；账号profile JWT不能当Key |
| 旧credit_grants兼容中继 | 用户host `/dashboard/billing/credit_grants`，total_available | 仅中继兼容，不能据此声明OpenAI官方Key可查余额 |
| 自定义BalanceURL/Path | M通用URL、header、字段表达式 | 不能把可配置能力计为新增已实现品牌；内置选择器应固化具体类型协议 |
| Remote Magpie / CPA plugin | 上游标准化聚合输出 | 依赖宿主的运输层，不计供应商独立quota |

证据：[M中继识别](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/balance.go#L94-L149)、[sub2api窗口](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/sub2api_usage.go#L15-L60)。

## 无真实quota或未完整接线的清单

下表是本次五个固定源码范围（M/N/C/U/P）的能力缺口，不是断言供应商现实中不存在任何接口。已在主表获得其它来源正向证据的品牌，不因N无handler而降为无支持。

| 分组 | 名称 / 能力边界 |
|---|---|
| 重点缺口 | Augment：M未发现实现，N/C无正向quota证据；Qwen Code：只有客户端接线/fixture，无原生OAuth quota；Qwen Token Plan / Bailian Token Plan：M明确无credits API；iFlow：N仅固定文案、C当前无原生adapter |
| 常见模型Key与云接入 | Anthropic APIKey、OpenAI APIKey、Gemini APIKey/Interactions、Vertex/Vertex Partner、Azure OpenAI、Bedrock/Bedrock Mantle/Bedrock xAI、Huawei MaaS、Baidu Qianfan、Qwen/DashScope国际/中国、Xiaomi Token Plan、Tencent个人/PAYG、xAI APIKey：无本次同认证真实quota；ChatGPT API/SIWC模型接入不等于WHAM查询 |
| 聚合与模型路由 | Together、Fireworks、NVIDIA NIM、ModelScope、Mistral、Nous Portal、PipeLLM、302.AI、CherryIN、鱼鱼连线、Kilo/Kilocode、Chutes、Cerebras、Cohere、Hugging Face、Hyperbolic、Featherless、Nebius、SambaNova、Venice、Perplexity及Agent/Web、Poolside、Morph、Voyage AI：无完整正向查询证据 |
| 隐藏/线索 | Trae在N只有线索，但P已有完整Auth usage/模型实现，已升级主表；Windsurf有GetPlanStatus RPC注释无完整解码认证链；TinyFish URL仅用于Key验证；不能计为额度adapter |
| 本地 / 搜索 / 媒体 | 本地Ollama、LM Studio、oMLX、MLX-Serve及下列N routing项没有独立云账户quota；local request/token/cost ledger只代表经该router的流量 |

Qwen否定证据：[M预设注释](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/provider/presets.go#L389-L401)。N完整差集以[registry索引](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/providers/registry/index.js#L2-L139)减[usage分派](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage.js#L39-L70)核对。为避免遗漏小品牌，下列保留**N全部105个无handler ID**；部分已有M/U正向证据，已在主表升级，不能把此差集当五源合并后的否定集合：

```text
agnes, alicode, alicode-intl, alims-intl, alitp-intl, anthropic,
api-airforce, assemblyai, atria, aws-polly, azure, bai, baidu, bazaarlink,
bedrock, bedrock-xai, black-forest-labs, blackbox, bluesminds, brave-search,
byteplus, cartesia, cerebras, chutes, cline, clinepass, cloudflare-ai,
cohere, comfyui, coqui, cursor, dahl, deepgram, edge-tts, elevenlabs,
exa, fal-ai, featherless, firecrawl, fireworks, fish-audio, gemini,
gitlab, google-pse, google-tts, grok-web, huggingface, hyperbolic,
inworld, jina-ai, jina-reader, kilo-gateway, kilocode, kimchi, linkup,
llm7, local-device, mimo-free, mistral, mmf, morph, muse, nanobanana,
nebius, nvidia, ollama-local, ollama-search, openai, opencode, openrouter,
perplexity, perplexity-agent, perplexity-web, playht, poolside, recraft,
runwayml, sambanova, sdwebui, searchapi, searxng, selfhosted-embedding,
selfhosted-stt, selfhosted-tts, serper, siliconflow, stability-ai, tavily,
tencent, tinyfish, together, tokenharbor, tokenrouter, topaz, tortoise,
v1m, venice, vertex, vertex-partner, volcengine-ark, voyage-ai, xai,
xiaomi-tokenplan, xquik, youcom
```

## 认证管理与危险操作边界

这些来源支持的账号发现、导入/导出、多账号、Keychain/SQLite读取、OAuth登录/refresh、账号启停、模型发现，是独立能力，不能由「有quota parser」推导全部完成。TokenHUD当前只读既有Auth路径/APIKey，不调用源项目管理服务来偷取/修改凭证。

| 操作 | 目录结论 |
|---|---|
| Codex reset credits consume、Claude reset grants领取/消费 | 危险不启用；会消耗权益，绝非普通刷新 |
| Meta muse-code/key POST | 危险不启用，先确认mint/轮换副作用 |
| xAI paid模式的 chat ping | 不作为quota；会消费模型调用，只是健康探测 |
| OAuth refresh / 上传 / 删除 / 字段编辑 / 自动续期写回 | 不放入普通只读fetch；过期明确提示原持有者更新授权 |
| CPA clear cooldown、9router合成block | 只改本地路由状态，不代表上游额度reset |
| 主动定时模型调用 | 单独的尝试开窗功能，需目标模型属于套餐池；不保证5h开窗，更不强制reset；本目录不执行 |

证据：[N Claude consume](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/open-sse/services/usage/claude.js#L184-L217)、[U Codex consume](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/f154fa9380825c4fe94bc577a9abaa7e505f8875/src/features/quota/providers/codex/data.ts#L492-L519)、[C管理操作](https://github.com/router-for-me/CLIProxyAPI/blob/01b24f1f95dc9b309765212c52b25b25e005ff01/internal/api/server_management_v8.go#L30-L69)、[N尝试开窗](https://github.com/decolua/9router/blob/1066c36281a040a563611bca0dbe2e6f6f8b17a3/src/shared/services/quotaAutoPing.js#L106-L180)。

## 当前实现与后续验证

当前55个类型均已有查询manifest与脚本。Groq只有速率限制响应头，不作为真实额度查询，已从内置资源排除。模型调用仅在manifest存在 `refreshUrl` 或 `authCallUrl` 时声明接入；仅查询类型尚未实现私有模型协议，因此模型测试与定时调用不可用，不能解释为缺少Key。资源数量、离线测试和保存成功均不代表供应商在线联通。最终Swift/Node回归与构建汇总由主线程据实际输出记录，此处不提前填写测试总数。

新增模板不会自动创建账号；搜索并选中内置类型后，用户填写名称及基础Key或选择类型支持的Auth文件，保存即采用默认查询。新增模型默认留空，必须选择目标套餐实际可用模型后才测试或启用计划。外部Auth只读，不自动浏览器登录、不刷新或写回Token。

当前Auth模式与格式以manifest的 `quotaAuthModes`、`credentialSource`、`alternatives`、`contextPaths` 为准；上游研究中的来源能力不能扩大实际UI能力。`credentialSource.alternatives`是明确JSON映射，`contextPaths`仅提取同账号查询所需上下文，不是任意文件解析器。明文host/连接记录导出JSON可读取，不等于已有原生Keychain、SQLite、TOML、加密客户端数据库或refresh-only文件导入器；没有默认路径的类型必须显式选择文件。缺少project、profile、region、accountId等同账号上下文字段时应给明确错误，不改用另一账号。

多币种余额逐币种保存与显示；period balance与钱包余额保留真实金额单位，不以当前余额伪造总上限、百分比或reset。额度字段缺失保持未知，赠金到期与套餐到期不当成自动补充窗口。

### 本地资源声明（实际能力）

下表从当前55份额度类型manifest核对。认证是额度查询可用模式；GPT的API Key模型调用与Auth订阅查询仍分开。格式数是credentialSource主映射加alternatives的数量，仅统计明确JSON映射，不保证任意原生格式都可自动发现。

| 类型 | 查询认证 | 模型调用 | Auth默认来源 | JSON映射数 | 本地声明 |
|---|---|---|---|---:|---|
| `agnes-code` | API Key / Auth文件 | 未接入；仅查询 | `显式选文件` | 1 | [manifest](../Sources/TokenHUD/providers/agnes-code/manifest.json) |
| `aihubmix` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/aihubmix/manifest.json) |
| `antigravity` | Auth文件 | 未接入；仅查询 | `显式选文件` | 1 | [manifest](../Sources/TokenHUD/providers/antigravity/manifest.json) |
| `autoclaw` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/autoclaw/manifest.json) |
| `autoclaw-cn` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/autoclaw-cn/manifest.json) |
| `catpaw` | Auth文件 | 未接入；仅查询 | `~/.meituan-catpaw/auth.json` | 2 | [manifest](../Sources/TokenHUD/providers/catpaw/manifest.json) |
| `claude-code` | Auth文件 | 未接入；仅查询 | `~/.claude/.credentials.json` | 2 | [manifest](../Sources/TokenHUD/providers/claude-code/manifest.json) |
| `cline` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/cline/manifest.json) |
| `cloudflare-workers-ai` | Auth文件 / API Key | 未接入；仅查询 | `显式选文件` | 1 | [manifest](../Sources/TokenHUD/providers/cloudflare-workers-ai/manifest.json) |
| `codearts` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/codearts/manifest.json) |
| `codebuddy` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/codebuddy/manifest.json) |
| `codebuddy-cn` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/codebuddy-cn/manifest.json) |
| `commandcode` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/commandcode/manifest.json) |
| `cursor` | Auth文件 | 未接入；仅查询 | `显式选文件` | 3 | [manifest](../Sources/TokenHUD/providers/cursor/manifest.json) |
| `deepseek` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/deepseek/manifest.json) |
| `devin` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/devin/manifest.json) |
| `factory` | API Key | 未接入；仅查询 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/factory/manifest.json) |
| `gemini-cli` | Auth文件 | 未接入；仅查询 | `~/.gemini/oauth_creds.json` | 2 | [manifest](../Sources/TokenHUD/providers/gemini-cli/manifest.json) |
| `github-copilot` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/github-copilot/manifest.json) |
| `glm` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/glm/manifest.json) |
| `gpt` | Auth文件 | 已声明；模型需选择 | `~/.codex/auth.json` | 3 | [manifest](../Sources/TokenHUD/providers/gpt/manifest.json) |
| `grok-cli` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/grok-cli/manifest.json) |
| `joycode` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/joycode/manifest.json) |
| `kimi-code` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/kimi-code/manifest.json) |
| `kimi-code-cn` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/kimi-code-cn/manifest.json) |
| `kiro` | Auth文件 | 未接入；仅查询 | `显式选文件` | 7 | [manifest](../Sources/TokenHUD/providers/kiro/manifest.json) |
| `loomy` | Auth文件 | 未接入；仅查询 | `显式选文件` | 1 | [manifest](../Sources/TokenHUD/providers/loomy/manifest.json) |
| `minimax-code` | Auth文件 | 未接入；仅查询 | `显式选文件` | 1 | [manifest](../Sources/TokenHUD/providers/minimax-code/manifest.json) |
| `minimax-code-cn` | Auth文件 | 未接入；仅查询 | `显式选文件` | 1 | [manifest](../Sources/TokenHUD/providers/minimax-code-cn/manifest.json) |
| `minimax-coding` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/minimax-coding/manifest.json) |
| `minimax-coding-cn` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/minimax-coding-cn/manifest.json) |
| `moonshot` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/moonshot/manifest.json) |
| `moonshot-cn` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/moonshot-cn/manifest.json) |
| `officeace` | Auth文件 | 未接入；仅查询 | `显式选文件` | 3 | [manifest](../Sources/TokenHUD/providers/officeace/manifest.json) |
| `ollama` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/ollama/manifest.json) |
| `opencode-go` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/opencode-go/manifest.json) |
| `opencode-zen` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/opencode-zen/manifest.json) |
| `openrouter` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/openrouter/manifest.json) |
| `orcaterm` | Auth文件 | 未接入；仅查询 | `显式选文件` | 3 | [manifest](../Sources/TokenHUD/providers/orcaterm/manifest.json) |
| `qoder` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/qoder/manifest.json) |
| `qoder-cn` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/qoder-cn/manifest.json) |
| `qwenwork` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/qwenwork/manifest.json) |
| `qwenwork-enterprise` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/qwenwork-enterprise/manifest.json) |
| `raccoon` | Auth文件 | 未接入；仅查询 | `显式选文件` | 3 | [manifest](../Sources/TokenHUD/providers/raccoon/manifest.json) |
| `stepfun` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/stepfun/manifest.json) |
| `stepfun-cn` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/stepfun-cn/manifest.json) |
| `trae` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/trae/manifest.json) |
| `trae-cn` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/trae-cn/manifest.json) |
| `vercel-ai-gateway` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/vercel-ai-gateway/manifest.json) |
| `workbuddy` | Auth文件 | 未接入；仅查询 | `显式选文件` | 3 | [manifest](../Sources/TokenHUD/providers/workbuddy/manifest.json) |
| `workbuddy-cn` | Auth文件 | 未接入；仅查询 | `显式选文件` | 3 | [manifest](../Sources/TokenHUD/providers/workbuddy-cn/manifest.json) |
| `xiaomi-mimo-desktop` | Auth文件 | 未接入；仅查询 | `显式选文件` | 2 | [manifest](../Sources/TokenHUD/providers/xiaomi-mimo-desktop/manifest.json) |
| `zai-coding` | API Key | 已声明；模型需选择 | `—` | 0 | [manifest](../Sources/TokenHUD/providers/zai-coding/manifest.json) |
| `zcode-start` | Auth文件 | 未接入；仅查询 | `显式选文件` | 3 | [manifest](../Sources/TokenHUD/providers/zcode-start/manifest.json) |
| `zed` | Auth文件 | 未接入；仅查询 | `显式选文件` | 1 | [manifest](../Sources/TokenHUD/providers/zed/manifest.json) |
