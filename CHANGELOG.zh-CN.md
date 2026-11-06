# 更新日志

[English](CHANGELOG.md) | 简体中文

所有更新按发布版本归档，版本号遵循 [Semantic Versioning](https://semver.org/)。尚未归属正式版本的改动放在 `Unreleased`；已发布内容保留在对应版本号和日期下。

## Unreleased

### 修复

- 按稳定原始记录 ID 识别 Magpie 原生 Codex Auth 快照，不再统一拒绝原生登录；备用路由开关不再控制 QuotaNest 账号启用状态。
- ZCode Start 从原始插件 slot 读取嵌套 JWT 和 device，不将 Coding plan Key 发往 Start 接口；绑定来源账号身份，不复制凭证。

## [1.0.0] — 2026-11-06

补齐后的 1.0.0 重发版，替换 2026-11-05 的原安装包和 tag。

### 核心能力

- 在四种悬浮窗样式与 Claude Code HUD 中显示 AI 账号额度、余额、用量窗口和重置时间。
- 通过定时小请求，尝试启动适用供应商按首次有效请求计时的动态 5h 窗口；不保证供应商开窗，请求也可能消耗额度。
- 以只读来源引用复用 Magpie、CPAMP、9router、cc-switch 中已适配的凭证和 API Key。QuotaNest 是配套辅助应用，不承担 API 网关或业务请求路由职责。

### 新增

- 原生登录时自动启动选项，以 macOS 登录项状态为准。
- 供应商选择与导入窗口的安全自助反馈：本机白名单诊断、预览确认后 gh 提交，以及复制／浏览器降级；无需安装或调用 Claude。
- 左下角“设置与外观”上方的一键 Star 按钮，仅用户点击时使用本机 gh，失败时提供项目页入口。
- 55 个供应商类型，区分额度查询和模型调用能力，按类型支持 Auth／API Key，并继承基础认证。
- 独立账号计划、额度展示、缓存状态，以及 App 运行期间每小时进行的来源引用同步。
- 简体中文／English 界面、供应商品牌图标、紧凑设置控件，以及全局与账号页联动的 HUD 显示选项。
- 旧 TokenHUD 账号文件和偏好的校验迁移，保留原始备份，失败时回滚。
- 双语 README、核心界面截图和中英两段 27 秒演示视频。

### 分发

- 版本化 macOS 应用打包及附注标签 `v1.0.0`。
- 同时包含 Apple Silicon 与 Intel 架构的 universal ZIP，要求 macOS 14 及以上，并提供 SHA-256 校验文件。
- 通过 `biedongbin/tap/quotanest` 提供 Homebrew cask 安装，包含额度适配脚本所需的 Node.js 运行时依赖。Homebrew 7 用户首次安装前，可用 `brew trust --cask biedongbin/tap/quotanest` 仅授权这个 cask。
- 应用采用 ad-hoc 签名，未声称 Apple Developer ID 签名或公证；cask 仅移除已安装 QuotaNest 应用的隔离属性。

[1.0.0]: https://github.com/biedongbin/QuotaNest/releases/tag/v1.0.0
