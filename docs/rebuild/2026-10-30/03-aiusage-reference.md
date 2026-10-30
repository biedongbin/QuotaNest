# AIUsage：证据采集与参考分析

采集日期：2026-10-30。仓库：[sylearn/AIUsage](https://github.com/sylearn/AIUsage)，默认分支 `main`；固定 SHA：[97136bc77a715bf33dd2fe6176ebd44d39e09b80](https://github.com/sylearn/AIUsage/commit/97136bc77a715bf33dd2fe6176ebd44d39e09b80)。仅只读 API、读取官方图片及四个指定源码文件；未运行程序、安装依赖、读取真实凭证或审查 TokenHUD。

## 项目定位与范围差异

[README.zh-CN.md:105][readme] 声明额度、费用、多账号、菜单栏、Keychain，并包含代理网关、CLI 账号切换及调用分析。明确列出 Codex、Copilot、Cursor、Antigravity、Kiro、Warp、Gemini CLI、Droid、Claude Code、OpenCode、Kimi、MiniMax。平台为 macOS 14+、SwiftUI，支持 Apple Silicon/Intel（README:19、182）。

本项目目标是额度查看与独立定时模型调用；AIUsage 的代理、账号切换器、调用分析不因参考而进入需求。其额度刷新、日志统计定时器不能证明存在定时模型调用。

## 三图视觉分析

图片均来自上述 SHA 的 `docs/images/`，已逐张 Read。下列绝对路径为临时审稿材料；未将图中账号信息转为样例或 fixture。

- [dashboard-overview.png](/tmp/aiusage-dashboard.2m5hOf/dashboard-overview.png)（[固定 SHA 官方原图](https://raw.githubusercontent.com/sylearn/AIUsage/97136bc77a715bf33dd2fe6176ebd44d39e09b80/docs/images/dashboard-overview.png)）：已见左侧导航，顶部今日/本月 Token 与费用，主体按应用展示热力图，底部“需要关注”列表有低额度、未连接、离线标签。可参考摘要与异常分层；热力图属于其统计范围。
- [provider-monitoring.png](/tmp/aiusage-provider.9p4TC5/provider-monitoring.png)（[固定 SHA 官方原图](https://raw.githubusercontent.com/sylearn/AIUsage/97136bc77a715bf33dd2fe6176ebd44d39e09b80/docs/images/provider-monitoring.png)）：已见搜索、渠道和应用筛选；应用分组下并排账号卡，卡内有计划、不同额度窗口、剩余百分比与更新时间，组头有刷新/暂停/连接账号入口。仅能证明这些可见布局与文案，未验证点击效果。
- [menu_bar.png](/tmp/aiusage-menubar.WxtHwH/menu_bar.png)（[固定 SHA 官方原图](https://raw.githubusercontent.com/sylearn/AIUsage/97136bc77a715bf33dd2fe6176ebd44d39e09b80/docs/images/menu_bar.png)）：已见状态栏图标加百分比，弹层顶部更新时间与刷新，主体按应用/账号分组，以多条进度条显示额度窗口，底部有打开、刷新、退出及费用摘要。图中账号切换按钮不属于本项目目标。

截图侧栏名称与当前源码存在差异，不能把仓库图片视为当前完整界面的验收记录。`docs/images` 文件名列表未发现专门添加/编辑图，故保留三图，未扩查其他图片。

## 四个源码文件事实

1. [AIUsage/Views/ContentView.swift:114][content]：`NavigationSplitView` 配合侧栏选择；160 行起分别路由订阅账号、API 提供商、统计、代理、设置等；219 行有供应商选择 sheet。已见页面组织方式，未验证窗口或手势行为。
2. [AIUsage/Views/ProvidersView.swift:5][providers]：账号与 API 提供商两类页面共用容器；49 行通过 `providerId` 打开 `ProviderAccountEditorView`，222 行按应用分组。491 行空态区分“筛选无结果”和“尚未添加应用”。编辑细节位于 `AIUsage/Views/ProviderAccountEditorView.swift`，仅定位引用，未读取。“可配置供应商模板”的字段与扩展机制未核实。
3. [AIUsage/ViewModels/ProviderRefreshCoordinator.swift:82][refresh]：定时刷新供应商；96 行定时读取本地 Token 统计；110 行同步调用分析。214、226 行分别用供应商/账号标识阻止同目标重复刷新，并保存 `result.userMessage`。已见错误状态赋值，未核实错误如何展示、旧额度是否保留、重试策略及休眠补偿。
4. [AIUsage/Models/AccountStore.swift:6][accounts]：账号登记与实时快照分开，22 行从 vault 加载；64 行起身份匹配考虑凭证、账号及工作区，147 行归一化/去重后持久化；330 行恢复隐藏账号，355 行说明隐藏保留凭证，393 行说明永久删除关联凭证。底层保险库实现未读。

## 借鉴与不采用

本文仅为参考资料，不代表最终方案。主线程读图后认为可借鉴供应商分组、多账号、套餐／额度／更新时间层级和菜单栏摘要。AIUsage 图中的“剩余百分比”不能与 TokenHUD 的“已用百分比”混用，显示口径在 S2 统一确定。以下为参考判断，尚非产品或技术决策。

| 分类 | 可核验依据 | 对本项目的参考边界 |
| --- | --- | --- |
| 可借鉴 | 账号卡、多额度窗口、更新时间 | 信息层次与状态表达 |
| 可借鉴 | 应用分组、账号级刷新、筛选空态 | 分清供应商/账号及失败反馈 |
| 可借鉴 | 菜单栏摘要与展开详情 | 快览层次；实现未核实 |
| 不采用 | 代理、网关、CLI 切换、调用分析 | 超出额度查看和定时调用目标 |
| 未知 | 未见独立定时模型调用证据 | 不能拿刷新定时器代替调用任务设计 |

## 尚待核实

未验证真实 UX、各家额度口径/接口、添加编辑流程、错误可见性、菜单栏源码、供应商模板与凭证安全实现；未证明可靠或无 BUG。截图中展示的能力也不能推导所有供应商均支持。

## 许可证边界

本次仅学习布局与思路，没有复制实现。仓库为 Apache 2.0；[LICENSE:89][license] 第 4 条要求再分发时提供许可证、标明修改、保留适用权利与署名声明；若原分发含 NOTICE，须保留适用通知。第三方组件/素材还应逐项核对，仓库另有 `THIRD_PARTY_NOTICES.md`，不能承诺全部可直接复制。后续若复制代码，需针对实际采用文件及分发方式处理许可。

[readme]: https://github.com/sylearn/AIUsage/blob/97136bc77a715bf33dd2fe6176ebd44d39e09b80/README.zh-CN.md#L105
[content]: https://github.com/sylearn/AIUsage/blob/97136bc77a715bf33dd2fe6176ebd44d39e09b80/AIUsage/Views/ContentView.swift#L114
[providers]: https://github.com/sylearn/AIUsage/blob/97136bc77a715bf33dd2fe6176ebd44d39e09b80/AIUsage/Views/ProvidersView.swift#L5
[refresh]: https://github.com/sylearn/AIUsage/blob/97136bc77a715bf33dd2fe6176ebd44d39e09b80/AIUsage/ViewModels/ProviderRefreshCoordinator.swift#L82
[accounts]: https://github.com/sylearn/AIUsage/blob/97136bc77a715bf33dd2fe6176ebd44d39e09b80/AIUsage/Models/AccountStore.swift#L6
[license]: https://github.com/sylearn/AIUsage/blob/97136bc77a715bf33dd2fe6176ebd44d39e09b80/LICENSE#L89

## 编辑流程源码补充

同一 SHA 的 [ProviderAccountEditorView.swift][editor]，行号如下：

- 仅传 `providerId`（8），未证明添加/编辑共用表单；Claude 订阅走独立页面（81）。
- 认证方案按供应商选取（69）；现有会话数量、API Key 方式及 `showKeyEntry` 决定主操作（233），另账号/手动 Key/导入入口按条件出现（260）；具体字段显隐未核实。
- 检测、登录、连接、成功为不同状态（20）；失败可返回/重试，连接中取消禁用，成功可完成/再加账号（196、298）。另账号入口指登录，不证明 CLI 切换。
- 仅见 `connectAPIKey`/`connect` 引用（240、245）；保存实现、错误展示未知。未运行，不证明真实交互。

[editor]: https://github.com/sylearn/AIUsage/blob/97136bc77a715bf33dd2fe6176ebd44d39e09b80/AIUsage/Views/ProviderAccountEditorView.swift#L7
