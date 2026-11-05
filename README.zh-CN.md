<p align="center">
  <img src="assets/branding/QuotaNest.png" width="112" alt="QuotaNest 额度巢图标" />
</p>
<h1 align="center">QuotaNest · 额度巢</h1>
<p align="center">把 AI 额度、账号和 Claude Code HUD，收进一个原生 Mac 工具。</p>
<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/English-Read_in_English-blue?style=for-the-badge" alt="English" /></a>
</p>
<p align="center">
  <img src="https://img.shields.io/badge/平台-macOS_14+-lightgrey?style=flat-square" alt="macOS 14 及以上" />
  <img src="https://img.shields.io/badge/原生界面-SwiftUI-orange?style=flat-square" alt="SwiftUI 原生界面" />
  <img src="https://img.shields.io/badge/内置供应商类型-55-blue?style=flat-square" alt="55 个内置供应商类型" />
  <img src="https://img.shields.io/badge/语言-简体中文_/_English-green?style=flat-square" alt="简体中文和英文" />
</p>

> 原生 macOS 菜单栏应用：集中查看 AI 账号额度，在悬浮窗里常驻用量，引用已有认证，并决定哪些账号显示到 Claude Code HUD。

## 10 秒了解

不用为了确认“哪个账号还有额度”反复打开供应商后台。QuotaNest 把额度窗口、余额、账号开关和调用计划放在一起；需要常驻查看时，可以切换四种悬浮窗样式。

**已有凭证继续由源工具管理。** 从 9router、cc-switch、CPAMP、Magpie 导入时使用只读引用，不再创建另一份长期保存的凭证副本。

![QuotaNest 账号概览](docs/screenshots/zh-CN/overview.png)

## 演示视频 · 27 秒

[![观看 QuotaNest 中文演示](docs/videos/quotanest-demo-zh-CN-poster.png)](docs/videos/quotanest-demo-zh-CN.mp4)

[观看／下载中文 MP4](docs/videos/quotanest-demo-zh-CN.mp4) · [English video](docs/videos/quotanest-demo-en.mp4)

视频展示当前原生 App，使用隔离的示例账号和演示额度，不发起付费模型请求。制作沿用 [CCS](https://github.com/biedongbin/claude-code-session-manager) 最终采用的“真实截图 → GSAP → HyperFrames”链路；复现源文件、具体工具和取证说明见 [视频制作说明](docs/video-source/README.md)。

## 功能一览

| 能力 | 具体用途 |
| --- | --- |
| 多账号概览 | 集中查看额度窗口、余额、重置时间、旧数据和配置状态。 |
| 55 个内置类型 | 当前 22 个类型声明“额度查询＋模型调用”，33 个类型仅支持额度查询；详见[供应商目录](docs/provider-catalog.md)。 |
| Auth／API Key | 认证方式由供应商类型声明，用量查询继承同一基础认证。 |
| 只读导入 | 引用 9router、cc-switch、CPAMP、Magpie 的既有记录，保留原始记录 ID 和 provider ID。 |
| 来源同步 | App 运行期间每小时检查，也可立即同步；只有唯一确认身份后才订正变化的源记录 ID。 |
| 四种悬浮样式 | 卡片、玻璃、紧凑、列表；任意位置拖动，点击显示标题，离开 5 秒后隐藏。 |
| Claude Code HUD | 在全局设置或账号展示页勾选输出账号，两处共用同一配置。 |
| 定时小调用 | 按本机时间执行请求，尝试启动适用套餐的动态用量窗口；请求消耗额度，不保证开启或重置窗口。 |
| 中英双语 | 在“设置与外观”即时切换简体中文／English，外观跟随 macOS 浅色／深色。 |
| 历史配置迁移 | 将旧 TokenHUD 账号与偏好迁入 QuotaNest，包含校验、备份及失败回滚。 |

## 从源码安装

需要 **macOS 14+**、**Swiftly 管理的 Swift 工具链**，以及供额度适配脚本使用的 **Node.js**，建议 Node.js 18+。

```zsh
git clone https://github.com/biedongbin/QuotaNest.git
cd QuotaNest
export PATH="$HOME/.swiftly/bin:$PATH"
zsh scripts/package.sh
open ~/Applications/QuotaNest.app
```

打包前先退出正在运行的 App。脚本会构建本地应用、打包图标和资源、进行 ad-hoc 签名，并安装到 `~/Applications`。这是本机构建流程，不代表已经提供经过公证的安装包下载。

系统 Command Line Tools 的 Swift 可能与当前包的 Manifest ABI 不兼容；请使用 `swiftly run swift …`，不要在构建中混用工具链。

## 核心界面

以下截图使用隔离演示数据，不包含私人凭证，也不代表已实测每个供应商的联通性。用户账号名称及供应商返回的原始内容不会随语言设置自动翻译。

### 1. 选择供应商类型

搜索内置类型，先看支持的认证方式和查询／调用能力。选择类型只打开草稿，不会立即创建账号。

![带品牌 Logo 的供应商类型选择](docs/screenshots/zh-CN/provider-catalog.png)

### 2. 配置 API Key 或引用已有 Auth

每个类型决定支持哪些认证方式。Auth 引用已声明格式的 JSON 授权文件；API Key 使用基础连接。额度查询复用同一认证，无需再填一套独立查询 Key。

| API Key 基础连接 | 已有 Auth 文件 |
| --- | --- |
| ![API Key 连接配置](docs/screenshots/zh-CN/connection-api-key.png) | ![只读 Auth 授权来源](docs/screenshots/zh-CN/authentication.png) |

<details>
<summary>展开查看：账号编辑与仅 API 账号</summary>

![账号编辑表单](docs/screenshots/zh-CN/account-editor.png)

![仅 API 调用账号](docs/screenshots/zh-CN/api-only.png)

</details>

### 3. 查看额度和设置调用计划

额度详情区分计费窗口和账号身份。缺失值保持未知，失败查询不会伪装成刷新成功。

![账号额度详情](docs/screenshots/zh-CN/quota.png)

支持调用的类型可以选择目标套餐／额度池适用的模型，再设置本机时间计划。小请求只会**尝试**开启供应商支持的首次使用计时窗口，不是重置指令；每次调用都可能消耗额度。

![账号 API 调用计划](docs/screenshots/zh-CN/schedule.png)

<details>
<summary>展开查看：全部调用计划</summary>

![调用计划总览](docs/screenshots/zh-CN/schedules.png)

</details>

### 4. 导入已有账号

预览展示来源工具、供应商身份、源记录 ID、认证方式、额度适配及导入状态。不支持或未适配的行置灰不可选；滚动时列标题保持可见。

![只读来源导入与同步](docs/screenshots/zh-CN/import.png)

| 来源 | 当前支持边界 |
| --- | --- |
| 9router | 按 `providerConnections` 原主键与 provider 身份引用，认证结构必须已适配。 |
| cc-switch | 当前支持 Claude 命名空间，按 `id + app_type` 识别；其他命名空间显示不支持。 |
| CPAMP | 按文件名和类型引用已支持的 CPA JSON 授权文件。 |
| Magpie | 支持已适配的 provider Key 与插件凭证槽，保留原 provider ID，可选择 portable 配置目录；原生 CLI／Keychain 持有的登录不导入。 |

导入账号的连接字段只读，请到来源工具维护凭证；本地仍可控制启停、显示、查询和删除关联。删除关联不删除源数据。

自动同步只在 **QuotaNest 运行期间**每小时执行。源记录 ID 变化时，必须唯一确认身份且类型／协议兼容才订正。候选歧义、缺少证据，或 ID 与 Token 同时变化但无可信关联时，需要人工核对。来源同步不会发起模型调用。

### 5. 四种悬浮窗样式——全部展示

四种样式使用同一套账号数据和供应商品牌映射。彩色 Logo 保留原色，单色 Logo 随外观调整。

| 卡片 | 玻璃 |
| --- | --- |
| ![卡片悬浮窗](docs/screenshots/zh-CN/floating-card.png) | ![系统深色外观下的玻璃悬浮窗](docs/screenshots/zh-CN/floating-glass.png) |

| 紧凑 | 列表 |
| --- | --- |
| ![紧凑悬浮窗](docs/screenshots/zh-CN/floating-compact.png) | ![列表悬浮窗](docs/screenshots/zh-CN/floating-list.png) |

- **卡片**：每个账号一个卡片，各额度窗口并列显示。
- **玻璃**：突出最高用量窗口，其他周期作为次级信息展示。
- **紧凑**：小行距、不使用分隔线，适合少占屏幕空间。
- **列表**：名称、周期、进度条和数值分列对齐，账号之间有分隔线。

单击菜单栏项目开关快览，双击切换悬浮窗，右键打开操作菜单。悬浮窗任意位置都可按住拖动；标题默认隐藏，点击后显示，鼠标离开 5 秒后隐藏，移回取消计时。**外观跟随 macOS；当前没有 App 内独立主题切换开关。**

<details>
<summary>展开查看：菜单栏快览</summary>

![菜单栏账号快览](docs/screenshots/zh-CN/menu.png)

</details>

### 6. 勾选 Claude Code HUD 账号及调整设置

“设置与外观 → Claude Code HUD”支持横向勾选并自动换行，与账号的“展示”页共用同一状态。修改立即同步，HUD 写入失败会恢复原选择；停用账号保留偏好，重新启用后恢复。

![语言、紧凑下拉框与 HUD 选择](docs/screenshots/zh-CN/settings.png)

![账号独立展示设置](docs/screenshots/zh-CN/account-display.png)

下面是用户补充的 Claude Code HUD 实际输出示例，发布前已裁掉顶部项目目录行，仅保留供应商额度内容。

![Claude Code HUD 输出示例](docs/screenshots/claude-code-hud.png)

## 数据、认证与历史迁移

| 项目 | 位置／行为 |
| --- | --- |
| 应用 | `~/Applications/QuotaNest.app` |
| 账号清单 | `~/Library/Application Support/QuotaNest/providers/` |
| 偏好域 | `local.quotanest` |
| Claude HUD 集成 | `~/.claude/hud/` 及 Claude 的 `settings.json`，支持 `CLAUDE_CONFIG_DIR`。 |
| 旧 TokenHUD 数据 | 在初始化语言、账号及后台任务前自动迁移；原始数据归档到 `QuotaNest/MigrationBackups/`，并生成迁移报告。 |

导入凭证在本次请求时从来源解析，长期账号配置只保存引用。手工配置的 API Key 属于 App 自有凭证，以受限文件权限存储；外部 Auth 文件不会被自动刷新或覆盖。

不要为了导入而手工把外部授权文件搬入 App 目录。Keychain、加密或未适配的结构，不会因为能导出就自动获得支持；App 不提供浏览器 OAuth 登录流程。

## 自定义额度接口

自定义账号使用 **API Key**，支持 OpenAI 兼容或 Anthropic 兼容模型调用。填写完整额度 URL；默认 HTTP GET 查询继承基础 Key。不提供额外查询 Key／Cookie，也不猜测 billing 路径。

标准额度 JSON 支持以下字段，也可由 `data` 包装：

```json
{
  "five_hour": { "used_percentage": 25, "resets_at": 1793462400 },
  "seven_day": { "used_percentage": 40 },
  "windows": [
    { "label": "本月", "amount": 12, "limit": 50, "unit": "USD" }
  ]
}
```

详细边界见[供应商目录](docs/provider-catalog.md)、[账号与认证契约](docs/account-management-rebuild.md)和[验证记录](docs/account-management-verification.md)。内置适配不等于所有供应商、账号和套餐均已完成真实联通验证。

## 开发与素材复现

```zsh
export PATH="$HOME/.swiftly/bin:$PATH"
swiftly run swift build
# 按改动范围选择测试：
swiftly run swift test
```

隔离截图不会启动真实账号查询或计划：

```zsh
QUOTANEST_RENDER="$PWD/.build/demo-zh" \
TOKENHUD_RENDER_ONLY=settings-light \
.build/debug/QuotaNest -quotanest.appLanguage zh-Hans
```

`TOKENHUD_RENDER_ONLY` 是保留的诊断环境变量兼容名。全部公开图片见[截图清单](docs/screenshots/capture-manifest.json)。视频命令、CCS 历史链路取证及真实时长／编码检查见[视频源文件说明](docs/video-source/README.md)。

## 参考与品牌素材

README 组织方式和视频制作参考 [claude-code-session-manager / CCS](https://github.com/biedongbin/claude-code-session-manager)。品牌图来自已记录的 Magpie／LobeHub 分发素材、对应产品包和官网素材；部分类型使用有证据的官方厂商或品牌家族标志，并非精确产品 Logo。

来源和第三方声明见[品牌素材说明](Sources/TokenHUD/Resources/ProviderLogos/README.md)。品牌名称、商标及图形归各供应商所有，仅用于标识，不表示获得其背书。
