# TokenHUD

macOS 菜单栏供应商账号管理 App。为同一供应商的多个订阅账号分别管理 API 连接、可选额度查询、调用计划和 Claude Code HUD 展示。

## 使用

- 单击菜单栏打开／关闭账号快览，双击切换悬浮速览，右键打开常用操作菜单。
- 在账号管理中添加账号，选择内置供应商类型或自定义兼容 API；复制账号可沿用非敏感配置，所有凭证需重新填写，计划默认暂停。
- API 配置包含 Base URL、API Key、OpenAI／Anthropic 协议及测试模型。测试与定时调用使用同一配置；调用成功不保证供应商已重置 5 小时额度。
- 额度查询凭证独立于 API Key。没有额度查询接口也可以管理账号、测试 API 和设置调用计划。
- 每个账号可控制菜单／悬浮窗展示及 Claude HUD 输出；同类型账号使用各自缓存和稳定标识。

## 开发与验证

必须使用 swiftly 工具链：

```zsh
export PATH="$HOME/.swiftly/bin:$PATH"
swiftly run swift build
swiftly run swift test
node --test scripts/test-account-query-providers.mjs scripts/test-provider-web-parsing.mjs
node --test scripts/test-gpt-provider.mjs scripts/test-cline-provider.mjs
```

离线演示截图不会启动真实账号查询和计划：

```zsh
TOKENHUD_RENDER="$PWD/.build/account-preview" .build/debug/TokenHUD
```

## 打包安装

```zsh
zsh scripts/package.sh
open ~/Applications/TokenHUD.app
```

打包会替换本机安装的 App，需先退出运行中的 TokenHUD。

## 供应商类型与账号

内置类型来自 `Sources/TokenHUD/providers/`。每个类型提供 `manifest.json`、`fetch.sh` 和默认配置；协议、固定地址和查询逻辑由类型提供，主框架自动扫描，不按供应商名称分支。

账号实例位于 `~/Library/Application Support/TokenHUD/providers/`，通过 `template` 引用类型，独立保存凭证、缓存和调用计划。凭证写入 Claude 配置目录的 `hud` 子目录，权限为 0600；支持 `CLAUDE_CONFIG_DIR`。

GLM 使用独立的网页 Token。Ollama 的 Cookie 查询读取设置页 HTML；OpenCode Go 优先查询 Console 组织额度接口，并兼容旧 workspace 页的静态 Seroval 数据。两者继续兼容已有 API Key 查询。网页字段契约依据公开固定提交实现并通过离线样本验证，尚未使用真实订阅账号进行在线验收；详情见 [网页查询契约](docs/provider-web-query-contracts.md)。

## 自定义额度接口

选择“查询接口”，配置完整查询 URL 及独立 Bearer Key。App 对该精确地址发送 GET，不自动拼接 billing 路径。接口可返回以下格式，也支持 `data` 包装：

```json
{
  "five_hour": { "used_percentage": 25, "resets_at": 1793462400 },
  "seven_day": { "used_percentage": 40 },
  "windows": [
    { "label": "本月", "amount": 12, "limit": 50, "unit": "USD" }
  ]
}
```

窗口与重置时间可以缺省。缺失数据保持未知；失败时只有确认同账号身份的旧数据才会保留，并标为旧值。

## Claude Code HUD

在账号的展示页选择需要同步的账号，再使用“写入 HUD”。App 为每个账号写入动态缓存映射并合并 `settings.json` 的 `ACCOUNT_ENVS`，保留其他工具的账号条目。HUD 渲染只读取这些 App 管理的快照。

本轮需求、改造边界与验证重点见 [账号管理重构说明](docs/account-management-rebuild.md)，实测结果和未验项见 [交付验证记录](docs/account-management-verification.md)。
