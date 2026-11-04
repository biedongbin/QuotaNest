# TokenHUD

macOS 菜单栏供应商账号管理 App。每个账号以 **Auth 认证调用／API Key 调用**为基础接入，用量查询通常继承同一认证，定时 API 调用用于尝试主动开启动态 5h 窗口，提高工作时间内的额度利用机会。

当前需求与技术契约以 [2026-11-04 三层需求](docs/account-management-rebuild.md) 为准。该文档区分目标与待验项；Auth 与认证继承改造的最终结果须由本轮验证证明，不能从本 README 推断所有供应商已经真实联通。

## 使用

- 单击菜单栏打开／关闭账号快览，双击切换悬浮速览，右键打开常用操作菜单。
- 在账号管理中添加账号，选择内置供应商类型或自定义兼容 API；复制账号可沿用非敏感配置，所有凭证需重新填写，计划默认暂停。
- 基础接入选择 Auth 或 API Key；OpenAI／Anthropic 是调用协议。Auth 当前只读既有本机 CLI／JSON 授权来源，不表示 App 已实现浏览器 OAuth 登录。
- 用量查询通常复用基础接入的同一认证；查询地址和解析可以不同，不常规要求第二套查询 Key。没有查询接口仍可管理账号、测试调用和设置计划。
- 定时小请求用于尝试主动开启按首次使用计时的动态 5h 窗口，不是强制 reset 或余额刷新；例如工作 09:00–18:00 时可考虑 05:00／10:00／15:00，但效果取决于真实供应商机制。调度模型必须适用于目标套餐／用量池，不能只按名称看起来便宜来推荐。
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

账号实例位于 `~/Library/Application Support/TokenHUD/providers/`，通过 `template` 引用类型，独立保存基础接入配置、缓存和调用计划。API Key 等 App 自有凭证写入 Claude 配置目录的 `hud` 子目录，权限为 0600；支持 `CLAUDE_CONFIG_DIR`。Auth 按只读 CLI／JSON 来源使用，不擅自写回外部授权来源。

旧 GLM 网页 accessToken，以及 Ollama／OpenCode Go 的 Cookie、HTML、Console／Seroval 适配，属于历史特殊兼容，不再定义正常接入的认证模式。默认方向是用量查询继承基础接入认证；旧网页适配的公开取证、离线样本与未在线验收边界保留在 [历史网页查询契约](docs/provider-web-query-contracts.md)，不作为常规要求第二套凭证的依据。

## 自定义额度接口

自定义查询可配置完整查询 URL，认证通常继承基础接入，不常规新增独立 Bearer Key；具体支持与继承路径须按本轮契约验收。查询地址与模型调用地址可以不同，不自动猜测 billing 路径。既有标准 JSON 解析接受以下格式，也支持 `data` 包装：

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
