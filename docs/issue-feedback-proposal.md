# 添加供应商／导入问题反馈：可行性提案

状态：探索提案，未实现。核对基线 `531ea2f`（2026-11-06）；仅检查源码、CLI 帮助和官方网页。
本轮未调用模型、未创建 issue、未读取用户凭证／原始配置／数据库／日志／会话，未修改产品代码。

## 结论与建议

可以实现“入口按钮 → 填写问题 → 审阅草稿 → 本机 gh 提交”；优先交付无需 AI 的白名单反馈。
Claude 只能总结 App 已生成的安全 JSON，不能承担任意文件扫描、运行信息采集或日志脱敏。
当前证据不足以证明“复用现有 Claude 登录 + 严格隔离全部隐私”，因此 AI 默认关闭；隔离不能验收就继续使用人工草稿。

## 现有入口及数据边界

| 位置 | 当前行为 | 建议入口 |
| --- | --- | --- |
| [SettingsCenterView](../Sources/TokenHUD/ui/SettingsCenter/SettingsCenterView.swift#L25) | 工具栏添加账号、导入账号；导入使用 sheet | 复用同一反馈协调器，避免重复弹框 |
| [TemplateCatalogView](../Sources/TokenHUD/ui/SettingsCenter/ConfigTabView.swift#L249) | 类型搜索、空结果、选择类型 | 标题旁“反馈问题／申请支持”；空结果处同入口 |
| [ImportCenterSheet.header](../Sources/TokenHUD/ui/SettingsCenter/ImportCenterSheet.swift#L404) | 来源选择、扫描、逐项导入 | 标题旁“反馈导入问题” |
| [扫描状态](../Sources/TokenHUD/ui/SettingsCenter/ImportCenterSheet.swift#L441)／[失败行](../Sources/TokenHUD/ui/SettingsCenter/ImportCenterSheet.swift#L493) | 超时、自由文本错误、来源与记录身份 | 错误旁入口，仅预选操作阶段与错误枚举 |

当前行包含自定义名称、provider ID、record ID、note、localizedDescription；不得把整行或错误字符串传入反馈。
[ProviderManifest](../Sources/TokenHUD/Models.swift#L39) 当前没有适配器 schemaVersion；已有其他存储版本不能冒充适配器版本。
新增反馈诊断 DTO 和错误分类映射，不能直接 Codable 编码现有 manifest、candidate、cache 或模型对象。
拟议字段示例：`source: ccSwitch`、`stage: scan`、`errorCode: scan_timeout`、`httpStatus: null`；不是已有诊断协议。
`token`、`apiKey`、`authorization` 等字段和一切未知键均拒绝；内置 templateID 才允许输出，适配器版本缺失则不伪造。

## 弹框与发送流程

1. 单例弹框填写：问题标题、复现步骤、预期、实际结果；阶段／错误分类用枚举，附带诊断可逐字段查看并取消。
2. 明示：“AI 总结会将下列内容发送至 Claude 或所配置的模型服务，消耗你的额度／产生费用”；默认不勾选。
3. 点击生成才授权可选模型处理；自动诊断先经 DTO 白名单校验，用户文字显示敏感检测结果，命中明显密钥时阻止继续。
4. 检测只是辅助，不能保证识别所有隐私。AI 前可审阅发送内容；AI 输出仍是待审稿，不自动采用为事实。
5. 最终完整预览 GitHub 标题、正文和固定公开仓库，说明 issue 将公开且显示 GitHub 发帖身份。
6. 用户最后点击一次“确认提交到 GitHub”才执行 gh；编辑正文后必须重新展示，不能提交旧快照。
7. 状态可见：准备、总结、待审阅、提交、成功 URL／失败分类；X、Esc、取消及键盘焦点均有完整行为。

## 采集层白名单

| 可以自动采集 | 来源／约束 |
| --- | --- |
| App 版本、build；macOS 大版本、架构 | bundle／系统 API，不收主机名或完整系统报告 |
| 操作阶段、错误分类、HTTP 状态码 | 新增强类型诊断事件；不附错误描述、URL 或请求上下文 |
| 内置 templateID／slug、适配器 schemaVersion | 仅匹配 App 随包白名单；自定义供应商统一记 custom；缺版本记 unavailable |
| CLI 是否存在及版本 | 受控执行版本检查，输出只解析版本字段，不上传可执行路径 |
| 扫描、选中、成功、失败等数量 | 仅使用已有内存计数，不触发重新扫描或重读任何来源 |

禁止自动采集 token、API Key、cookie、认证头、请求／响应体、源记录内容、账号／邮箱／用户名／路径。
也禁止会话、用户模型 prompt、完整环境、代理地址、数据库、原始配置、原始 CLI 输出和完整日志。
不上传来源记录 ID、账号别名、供应商用户自定义名；可用静态来源枚举表达导入适配器种类。
正则脱敏后的原始日志仍不满足“严格保证没隐私”；禁止读取或附加现有原始日志，也不自动附截图。
可新增 `SafeDiagnosticEvent` 白名单环形缓冲，仅记录阶段、内置类型、错误分类、HTTP 状态、耗时／相对时间桶和计数；这些强类型安全事件可作为运行日志附加，不接收自由文本或原始错误。
白名单以外字段在序列化边界拒绝，不依赖提示词约束；模型输入和 issue 正文分别再次校验。

## 本机 CLI 证据与隔离限制

实际只读结果：Claude Code `2.1.296`、gh `2.88.1`；目标公开仓库读取权限返回 admin／push／pull 为 true。
这只证明当前本机 gh 能访问仓库，不证明其他用户的认证、issue 创建能力或网络可用；未做提交验证。

| 本机 `claude --help` 已出现的标志 | 能做什么／不能证明什么 |
| --- | --- |
| `--bare` | 跳过项目指令自动发现、hooks、自动记忆等；skills 仍可显式解析；不读 OAuth／钥匙串 |
| `--safe-mode` | 关闭用户定制且保留认证；managed policy 及内置能力仍可能生效 |
| `--restricted` | 限制命令工具／内置文件工具目录并忽略用户、项目、本地设置；managed 设置仍生效 |
| `--setting-sources` | 支持 user／project／local 列表；空字符串的具体 CLI 组合本轮未运行验证 |
| `--strict-mcp-config`、`--mcp-config` | 指定独占 MCP 配置；候选为空 `{"mcpServers":{}}`；本轮未验证组合运行 |
| `--tools ""` | 移除内置工具，不等于禁用启动 hooks、MCP 或 CLI 自身文件读取 |
| `--disallowedTools "mcp__*"`、`--disable-slash-commands` | 本机支持工具拒绝规则与禁用全部 skills；不能替代进程隔离 |
| `--no-session-persistence` | print 模式不保存可恢复会话；不保证无其他临时／调试文件或服务端留存 |
| `--no-chrome`、`--permission-prompts none` | 禁用浏览器集成、无人回答权限请求时自动拒绝；不是文件访问沙箱 |
| `--system-prompt`、`--output-format json`、`--max-budget-usd` | 固定总结任务、结构化返回、费用估计上限；费用可能超过估计阈值 |

普通 `claude -p` 会像交互模式加载用户／项目定制，并跳过信任对话；单独禁工具不够。[CLI 参考][1]、[程序化运行][2]。
官方文档明确 `--tools` 不影响 MCP；设置来源为空仍不排除全局配置、managed policy 和部分连接器。[CLI 参考][1]、[设置来源边界][3]。
`--bare` 的 Anthropic 认证仅接受已由用户在 CLI 环境配置的 API Key 或显式 apiKeyHelper，不能复用订阅登录。[2]
不能为了启用功能让 App 读取、复制或导出密钥；依赖不受约束 apiKeyHelper 的方案也不算隔离通过。

## 待验证的 AI 执行契约

候选是 argv 组合：`-p --bare --restricted --tools "" --disallowedTools "mcp__*" --disable-slash-commands`，
再加 `--strict-mcp-config --mcp-config '{"mcpServers":{}}' --no-session-persistence --no-chrome --permission-prompts none`，
固定 `--system-prompt` 与 `--output-format json`，由 stdin 传安全 JSON；以上仅设计，未实际调用或验证组合。
`--safe-mode` 可保留原有登录，但有 managed hooks 等边界；不作为隐私已获保证的 bare 替代品。

- 用独立空 cwd，禁止 resume／continue／add-dir；显式系统提示避免默认提示带入个人 cwd 等上下文。
- 子进程环境从空白 allowlist 构造，只放固定 locale、受控 runtime PATH／临时目录等必需项；不继承全量 CLI 环境。
- 原有登录需要的 home／钥匙串访问须单独证明最小范围；不复制凭证、不把环境或授权来源内容放入模型输入。
- 空 cwd／清洁环境不是 OS 隔离。需限制整个 Claude 进程的文件读取，而非只限制 Bash 子进程或文件写入。[4]
- whole-process sandbox 必须默认拒读用户私有文件，仅允许 CLI runtime、已审 JSON、受控输出及必要认证通道；出站限定选定模型服务。
- 不装新运行时来掩盖未知；认证最小访问、managed policy、CLI 元数据仍可能外发，未证明边界就关闭 AI。
- 超时、输入字节数、stdout／stderr 字节数、正文长度和费用上限是发布前必填正有限配置；未设置则拒绝启动。
- 取消／超时终止进程及子进程并清理临时文件；超长、非 JSON、缺 result 或 CLI 报错均保留人工草稿，不自动重试模型。
- CLI 元数据、stderr、session ID、文件路径不进入 issue；只采用经验证的总结文本，不执行其中的命令、路径或链接。
- 不使用 `--dangerously-skip-permissions`、bypassPermissions 或 `--yolo`。

## 可见终端、gh 和降级

已阅读 terminal-opener 技能与启动器：支持 executable + argv、`shell:false`、默认 dry-run／JSON 计划、能力探测。
该技能当前只支持 WezTerm；本机 `--detect --json` 返回 not-installed（exit 1），这是现有 adapter 限制，不代表原生 Terminal 技术不可行。
原生 Terminal 可另规划 adapter：受控 0700 `.command` 脚本配合 NSWorkspace／可靠 launcher，仅固定启动 helper；用户文字走 stdin／私有 IPC，绝不嵌入脚本；此方案未实现、待验证。
启动器完整继承环境；mux 可能复用既有终端环境。必须由受控 helper 再构造环境／隔离，不能声称启动器本身保证隐私。
如后续实现可见终端，先生成可审阅计划；严格模式应独立启动并绕过用户终端配置。helper 通过私有 IPC 取得安全 JSON。
终端只显示安全进度和状态，不显示输入全文、认证、环境、原始错误或诊断文件路径；不拼接 AppleScript／shell 命令字符串。
终端缺失时返回 App 内进度；Claude 缺失、离线、隔离或认证失败时生成同一人工草稿，不自动安装／升级。

最终发送只由 App 调 gh，模型与终端 helper 不获得提交权限；使用 Process executableURL／arguments，不用 shell。
固定参数为 `issue create --repo github.com/biedongbin/QuotaNest --title <已审标题> --body-file <私有正文文件>`。[5]
子进程固定 `GH_HOST=github.com`，关闭 `GH_DEBUG`、交互提示及自动打开浏览器，防止企业主机环境误投；只让 gh 读取其已有认证，不将其环境传给 Claude。
正文文件随机创建、目录 0700／文件 0600；提交前校验文件归属、内容哈希及固定仓库，结束后清理；不附加标签／assignee／附件。
提交中按钮禁用；每份草稿使用随机请求 ID 并将标记纳入审阅正文，重试前查该标记；网络结果不明时先核对，禁止盲目双发。
成功需退出状态及固定仓库下的有效 issue URL；失败显示类别并保留草稿。gh 认证只由 gh 使用，App 不读认证文件／token。
gh 不可用／未登录时可复制草稿或打开固定 issues/new；URL body 仅限审过的短文本且长度有上限，长文本复制后由用户粘贴。
浏览器路径始终由用户审阅再点提交；网络离线只提供复制。去重核对不可用时提示提交状态待确认，不自动重发。

## 最小分阶段实现与验收

1. P1：三个入口共用表单＋白名单 DTO＋人工预览＋复制／浏览器降级；验证禁止字段无法序列化、关闭／取消／重复打开和敏感提示。
2. P2：App 内 gh 提交器；以 fake gh 验证 argv、固定 host/repo、最终快照、一次确认、超时／双击／结果不明处理；真实提交需另行授权。
3. P3：可选 CLI 总结＋可见终端；仅用合成 canary 文件验证拒读、无 hooks/MCP/tools、无持久会话、清洁环境与取消清理，之后再独立授权模型验收。
4. 若 P3 无法证明严格边界，交付 P1/P2；不得退回读取原始日志、配置或数据库来“补充诊断”。

## 成本、许可与权威资料

模型服务调用会离开本机，按用户自己的 API／供应商合同计费；订阅适用性不能仅根据“CLI 已登录”推断。
官方条款区分未修改 CLI 中的用户自有订阅登录与第三方产品提供登录／代用户路由凭证；运行于产品还涉及 Commercial Terms。[6]
发布前核对本集成适用条款；不代登录、不代理收费、不复制订阅 token、不把 Anthropic 商标当自有功能品牌。[条款][6]、[SDK 认证说明][7]。
本轮只证明帮助所列能力与代码入口；尚未验收隔离、认证复用、模型花费、终端实窗或 issue 发送。

[1]: https://code.claude.com/docs/en/cli-reference
[2]: https://code.claude.com/docs/en/headless
[3]: https://code.claude.com/docs/en/agent-sdk/claude-code-features
[4]: https://code.claude.com/docs/en/sandbox-environments
[5]: https://cli.github.com/manual/gh_issue_create
[6]: https://code.claude.com/docs/en/legal-and-compliance
[7]: https://code.claude.com/docs/en/agent-sdk/quickstart
