# 一键反馈：使用方式与隐私边界

状态：已并入 2026-11-06 补齐后的 v1.0.0。本文保留原提案路径，记录当前实现及尚未开放的实验；旧 2026-11-05 安装包需重新安装才能获得反馈入口。

## 没有 Claude 也能反馈

入口位于“添加账号 → 供应商类型”标题旁，以及“导入账号”弹框标题旁。

1. 点击“反馈问题／申请支持”或“反馈导入问题”。
2. 填写标题、问题描述和可选复现步骤；不要填写凭证、邮箱、账号或私人路径。
3. 点击“生成并预览反馈”，查看将要发送的完整正文和诊断 JSON。
4. 确认内容无隐私，并同意在 `github.com/biedongbin/QuotaNest` 公开发布。
5. 有已登录的 `gh` 时直接提交并返回 issue 链接；没有 `gh` 或认证不可用时，复制草稿或在浏览器确认提交。

Claude 不是依赖项，不会自动安装。没有 Claude 时，白名单诊断、预览、复制、浏览器和 gh 提交都可使用。

## 自动诊断白名单

- App 版本及经过格式校验的构建短哈希。
- macOS 大版本和 CPU 架构，不收主机名、完整系统报告或用户路径。
- 操作入口、来源工具和阶段枚举，已随 App 打包的类型 ID；自定义类型统一记为 `custom`。
- 已有内存中的候选、成功、跳过及失败数量，不为反馈重新扫描来源。
- `SafeDiagnosticEvent`：仅阶段、来源枚举、错误分类、有效 HTTP 状态、耗时桶和计数。当前导入入口生成当前阶段的安全事件，不读取完整历史日志。
- 是否发现 gh／Claude 的布尔值，不上传可执行文件路径或原始 CLI 输出。

账号名称、providerID、recordID、note、原始错误文本、Token、API Key、cookie、认证头、请求／响应体、源记录、配置、数据库、完整日志、模型会话／prompt、代理信息、环境和截图均不自动附加。

诊断使用独立强类型 DTO；不直接编码 manifest、candidate、cache、配置或窗口模型。Claude 输入再次递归拒绝未知字段并重新编码白名单结构。

## 用户输入与最终确认

常见密钥、JWT、Bearer、密码／Key 赋值、邮箱及私人路径检测用于阻断明显敏感内容。检测只是辅助，不能识别任意自由文本中的所有秘密；用户必须人工审阅。

标题最多 160 字符／640 UTF-8 字节，最终正文最多 16 KiB。预览绑定固定标题、正文和请求 UUID；返回编辑或采用 AI 建议后，原确认失效，必须重新核对。

草稿仅保留在窗口会话中。取消会终止本次本机进程；结果不明确时保留原请求 ID，不自动重复发送。

## gh 提交与缺失降级

App 使用 `Process.executableURL` 和参数数组调用用户已安装的 gh，不拼接 shell。

- 固定仓库为 `github.com/biedongbin/QuotaNest`，固定 `GH_HOST=github.com`。
- 使用 gh 自己的默认本机认证；App 不读取认证文件或 Token，也不执行自动登录。
- 不继承 `GH_DEBUG`、企业主机覆盖、编辑器及完整父进程环境。
- 正文写入随机临时目录（0700）的文件（0600），通过 `--body-file` 传入，结束后清理。
- 每个命令有超时，stdout／stderr 合计上限 64 KiB；stderr 不外传，不显示原始 CLI 错误。
- 同一请求合并并发提交，记录已确认 URL，提交前后以请求标记只读核对。
- GitHub 搜索最终一致，因此不宣称 exactly-once。POST 后出现超时、取消或结果不明时冻结重发；“检查提交状态”只读查询，浏览器按钮只打开 issue 列表核对。
- 只接受固定仓库下、无用户信息／查询参数／片段的 HTTPS issue URL。

没有 gh、未登录或提交失败时，保留原草稿。浏览器反馈仍需用户自行确认；编码后的 URL 超过 7500 字节时先复制草稿，再打开固定新 issue 页面。

## Claude 整理研究：未接入 App

当前 App 不调用 Claude，反馈主链完全在本机生成草稿。下述隔离原型仅编译进测试目标，不随 App 分发；没有对应的用户操作按钮。

合成测试已证明私有文件拒读、外部拒写和取消边界，但同一严格 profile 的无授权 DNS 探针无法解析固定 Anthropic 主机。不能据此声称能实际调用模型，因此不放宽隐私保护来开放功能。

若后续解决安全网络通道并通过验收，仍必须先预览并单独同意向模型服务外发，明确可能产生费用；原型设计为受控 CLI 进程，不是已经实现的可见 Terminal adapter。

支持边界：

- 仅接受可验证的本机 native Mach-O CLI，使用 POSIX `realpath` 消除路径别名。
- 通过 `/usr/bin/sandbox-exec` 施加整个进程的 deny-default 沙箱；只允许 CLI 二进制、必要系统运行时和本次私有工作目录，拒读用户配置／记忆／MCP／私有文件，拒写外部文件，禁止 fork 和额外执行。
- 固定 `--bare --tools "" --disable-slash-commands --strict-mcp-config`、空 MCP 配置、禁止持久会话／浏览器／权限提示，固定总结任务，只接收已审安全 JSON。
- 使用空白构建的环境；只将已经存在的 `ANTHROPIC_API_KEY` 环境值交给 CLI 用于正常鉴权。它不进入参数、输入 JSON、临时文件、日志、诊断或 issue；App 不读取订阅 OAuth／Keychain，也不提供新 Key 输入框。
- 固定 Anthropic API 地址并关闭非必要流量；OS 只限制 443 出站，不声称具备域名白名单。不继承用户代理、Node 注入或自定义模型服务地址。
- 1 turn、CLI 估计预算 0.10 USD、最长 60 秒；stdout 最多 32 KiB、stderr 最多 8 KiB 且仅计数丢弃。费用估计不是严格账单保证。
- 只返回 CLI JSON 的 `result` 文本，最多 8 KiB，再做敏感内容检查；不采用 session ID 或其他 CLI 元数据，不执行模型返回的命令／链接。
- 超时／取消会终止进程组、回收进程并清理本次私有目录。

`--bare` 不读取现有订阅登录。没有兼容 API Key 环境、Node 包装器、CLI 参数不兼容、沙箱或 DNS／TLS 不可用时，整理失败并保留人工草稿；绝不退回普通 Claude 模式或原始日志扫描。

## 验证与限制

已使用模拟 gh 和合成 native CLI 验证缺工具、格式校验、参数／固定主机、文件权限、取消／超时、输出上限、未知状态不重发，以及沙箱拒读 canary／配置／MCP／symlink、拒绝外部写入和 fork。

未调用真实模型、没有发送真实测试 issue。真实 CLI 的网络和授权可用性尚未验收；这种限制不构成放宽隐私边界的理由。终端可见 adapter 不在当前实现范围。

## 参考资料

前期检查了 Claude Code `2.1.296`、gh `2.88.1` 的帮助及下列官方资料。普通 print 模式会加载本地定制，单独 `--tools ""` 不足以隔离，所以当前实现只使用上述受限路径。

- [Claude CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Programmatic execution](https://code.claude.com/docs/en/headless)
- [Settings and managed-policy boundaries](https://code.claude.com/docs/en/agent-sdk/claude-code-features)
- [Sandbox environments](https://code.claude.com/docs/en/sandbox-environments)
- [gh issue create](https://cli.github.com/manual/gh_issue_create)
- [Claude legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)

用户继续使用自己 CLI 的正常授权与适用条款。App 不提供 claude.ai 登录、不代理收费、不复制订阅 Token；产品集成与订阅使用的适用性须以官方条款和实际运行方式为准。
