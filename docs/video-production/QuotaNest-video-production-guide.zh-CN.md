# QuotaNest 项目介绍视频：真实制作链复盘与复现指南

> 本地取证日期：2026-11-09。文档性质：既有视频的制作复盘，以及未来复用的操作指南。本次只读仓库、Git 记录、现存图片与媒体元信息；没有重新截图、构建 App、生成视频、联网、安装软件、调用付费服务或发布。通用化成果为用户级 skill `evidence-based-product-video`，现已按用户要求移至 Claude Code 的用户级 skills 目录。

## 1. 这支视频实际是什么

QuotaNest 的介绍视频是**原生 App 的隔离演示截图，加说明文案和轻量动效的无声产品短片**。它用于双语 README 的快速产品介绍。它不是连续鼠标操作录屏，也不是 AI 生成画面。实际链路如下：

```text
产品事实与能力边界
  → 中英双语六段分镜
  → App 内 DiagnosticFixture + 原生窗口截图
  → 筛选并冻结公开 PNG、语言映射、品牌图
  → Python 组装本地 HTML + GSAP 暂停时间线
  → HyperFrames 在本地 Chrome 中逐帧渲染中间 MP4
  → FFmpeg 转码为兼容的 H.264 MP4、抽封面与验收帧
  → ffprobe / 哈希 / faststart / 人工视觉检查
  → README 引用仓库 MP4 与既有附件播放器
```

核心入口为 [build.py](../video-source/build.py#L201)，已有源说明为 [video-source README](../video-source/README.md)。实际渲染使用 HyperFrames CLI；本项目没有通过 Remotion、Manim、`am video` 或配音服务制作这两份成品的证据。

### 成品实测

2026-11-09 对现存 MP4 执行只读 ffprobe，所得数值与历史 [机器验证记录](../videos/verification.json) 一致：

| 交付 | 时长 | 分辨率 / 帧率 | 编码 / 像素格式 | 字节数 | 帧数 / 音轨 |
| --- | ---: | --- | --- | ---: | --- |
| [英文视频](../videos/quotanest-demo-en.mp4) | 27.000 s | 1440 × 900 / 30/1 fps | H.264 / yuv420p | 5,062,436 | 容器报告 810；无音轨 |
| [中文视频](../videos/quotanest-demo-zh-CN.mp4) | 27.000 s | 1440 × 900 / 30/1 fps | H.264 / yuv420p | 4,440,424 | 容器报告 810；无音轨 |

[英文封面](../videos/quotanest-demo-en-poster.png)与[中文封面](../videos/quotanest-demo-zh-CN-poster.png)来自最终编码视频第 2 秒，历史记录尺寸均为 1440 × 900。两份 MP4 均低于本项目的 15,000,000 bytes 目标。历史 [verification.md](../video-source/verification.md#L14) 记录了完整解码各 810 帧、faststart、输出与输入哈希检查；本次父层另用 Python 只读重算了两语言成品与 `inputHashes` 合计 22 条 SHA-256，全部匹配、0 项不一致。本次没有重新完整解码或复测 MP4 atom 顺序，不能把这两项历史检查写成本次执行结果。

## 2. 证据范围、目录惯例与版本边界

根目录 [CLAUDE.md](../../CLAUDE.md#L5) 要求先说明范围、一次适当检查后收口；本次未发现适用于当前路径的 AGENTS.md。项目已把制作源放在 [video-source](../video-source/README.md)、媒体放在 [videos 验证记录所在目录](../videos/verification.json)、业务说明放在 [账号契约](../account-management-rebuild.md)。因此本复盘放在新的专题文档目录，保留既有制作源不动。[archive 说明](../archive/README.md#L3) 指定历史归档不作为当前规范；本次没有审阅其历史设计正文。

本次检查时 HEAD 为 `75b0e99`。Git 范围查询显示：

- `f99c554`（2026-11-05）：一次纳入双语截图、视频源、成品和验证文档。原生成品的时间依据来自该提交和 [2026-11-05 验证记录](../video-source/verification.md#L3)。
- `476a035`（2026-11-05）：双语 README 加入原生视频播放器附件引用。
- 此后应用有账号来源、顶部操作、刷新逻辑等变化。视频源和冻结图片仍对应制作时的产品状态；不要称它们是当前 HEAD 所有界面的实时录制。

本次用下列 Git 内容比较核实：当前已入库截图、视频源、成品 MP4/封面和验证 JSON，与 `f99c554` 的内容没有变化（退出码 0）。因此没有发现素材在该成品之后被替换的证据。这里核的是 Git 内容一致性；此外，父层在 2026-11-09 用本地 Python 对 [verification.json](../videos/verification.json) 的两条成品哈希及两语言 `inputHashes` 共 22 条记录逐项只读重算，全部匹配。Git 内容比较与 SHA-256 重算是两个独立检查，均不能替代重新渲染或真实业务验收。后来新增的附件发布记录单独见 [github-attachments.json](../videos/github-attachments.json)，不属于原始输入集合。

```sh
# cwd: 仓库根目录。本次实际执行，退出码 0。
git diff --exit-code f99c554 -- docs/screenshots docs/video-source \
  docs/videos/verification.json 'docs/videos/quotanest-demo-*'
```

必须区分三种可复现性：

| 层次 | 可做什么 | 不能据此承诺什么 |
| --- | --- | --- |
| 冻结素材合成 | 用已入库的截图、分镜、模板、图标重建相同叙事与规格的视频 | 不承诺在不同 Chrome、字体、编码器和硬件上得到相同 MP4 字节哈希 |
| 当前工作树重新截图 | 当前代码有隔离 fixture、原生窗口捕获和场景筛选入口 | 重新截图会受到当前 UI、时间戳、临时 fixture 路径、系统外观、窗口标题栏和显示环境影响，不是历史像素复刻 |
| 历史素材最初整理 | 截图清单记录场景与最终尺寸，部分原始缓存仍在 | 没有入库的一键截图筛选、重命名及所有裁边命令，不能声称从干净克隆一键得到历史全部 PNG |

### 结论到证据

| 结论 | 文件 / 入口 / 行，或媒体元信息 |
| --- | --- |
| 先分流诊断，render 模式不走正常后台引擎启动 | [AppLaunchMode.init](../../Sources/TokenHUD/AppConfigPaths.swift#L31)、[QuotaNestApp.init render 分支](../../Sources/TokenHUD/TokenHUDApp.swift#L41) |
| 演示账号、缓存、配置、偏好位于临时 fixture；演示执行器拒绝真实测试 | [DiagnosticFixture](../../Sources/TokenHUD/TokenHUDApp.swift#L598)、[renderSnapshots 内 model()](../../Sources/TokenHUD/TokenHUDApp.swift#L203) |
| 截取真实原生窗口，不能回退全屏截图 | [capture()](../../Sources/TokenHUD/TokenHUDApp.swift#L488)，尤其窗口 ID 捕获与无权限分支 |
| 每语言的确切图片来源、四种 HUD 的顺序 | [screenshots.json](../video-source/screenshots.json#L1) |
| 全部可编辑文案与时间段 | [storyboard.json](../video-source/storyboard.json#L1) |
| 原生场景到公开截图的清单与尺寸 | [capture-manifest.json](../screenshots/capture-manifest.json#L1) |
| GSAP 版本 3.14.2、本地库与许可证头 | [gsap.min.js](../video-source/vendor/gsap.min.js#L1) |
| 本地字体、固定画布、注册暂停时间线 | [template.html](../video-source/template.html#L5)、[时间线](../video-source/template.html#L47) |
| 构建、裁图、哈希、渲染、转码及验证 | [build_composition()](../video-source/build.py#L94)、[render()](../video-source/build.py#L175)、[verify()](../video-source/build.py#L149) |
| 成品真实参数 | 本次 ffprobe 表格；历史 [verification.json](../videos/verification.json#L1) |
| README 实际引用状态 | [英文 README](../../README.md#L30)、[中文 README](../../README.zh-CN.md#L30)；本次未联网检查附件可用性 |

## 3. 阶段一：从产品事实到文案和分镜

**输入**：制作时的原生 UI、[业务契约](../../CLAUDE.md#L30)、双语 README、供应商类型和导入能力。**输出**：[storyboard.json](../video-source/storyboard.json)，含六段时间、截图键名、中英标题、副标题、注释和画面标签。入口由 [main()](../video-source/build.py#L209) 读取，文案经 [scene_markup()](../video-source/build.py#L81) HTML 转义后进入模板。

| 时间 | 素材键 | 叙事目的与限制 |
| --- | --- | --- |
| 0–4.5 s | `accounts` | 一个 App 看到账号额度；“55 种”是制作时冻结文案，升级后应重新核对，不应由本视频推导当前供应商联通数 |
| 4.5–9 s | `authentication` | Auth / API Key；用量查询继承基础连接认证，不能写成独立查询凭证或已实现浏览器 OAuth |
| 9–13.5 s | `import` | 9router、cc-switch、CPAMP、Magpie 的只读来源引用；描述每小时同步与唯一身份匹配，不构成长期运行实测 |
| 13.5–18 s | `schedule` | 小调用尝试开启符合条件的动态 5h 窗口，必须保留“不保证开启”；不写成强制 reset 或余额刷新 |
| 18–24 s | `hud` | 卡片、玻璃、紧凑、列表全部可见，每种强调 1.5 s |
| 24–27 s | `accounts` | 品牌、产品定位、公开仓库标识与 macOS 14+ |

**前置条件与操作**：在仓库根目录编辑已存在的分镜源；这一阶段没有生成文案的模型命令。先核事实再改文字。验收每段只承担一个核心信息，双语含义相同，长句能在停留时间内读完，功能名称与该语言截图一致。没有证据支持的产品结果必须删除、改为意图或标为未验证。修正文案只需从 HTML 合成阶段重跑，不必重新获取截图。

**实现限制**：[storyboard.json 顶层规格](../video-source/storyboard.json#L2)并非完全参数化；[模板](../video-source/template.html#L40)、进度条、[构建器输出和 verify()](../video-source/build.py#L158)也硬编码了 27 秒、1440 × 900、30 fps。只改 JSON 顶层不会自动改完整视频规格。

## 4. 阶段二：隔离 fixture 与原生 UI 画面

### 原生素材如何产生

**输入**：本地 macOS 14+、可运行的 QuotaNest 可执行文件及 SwiftPM 资源包、系统已授予的屏幕录制权限、确定的语言。**输出**：指定场景 PNG、`render-observations.json`、原生交互诊断记录；随后人工挑选冻结为 [截图映射](../video-source/screenshots.json)指定的公开素材。

[AppLaunchMode](../../Sources/TokenHUD/AppConfigPaths.swift#L42)优先识别 `QUOTANEST_RENDER`（兼容 `TOKENHUD_RENDER`），进入 [render 分支](../../Sources/TokenHUD/TokenHUDApp.swift#L41)；创建 [DiagnosticFixture](../../Sources/TokenHUD/TokenHUDApp.swift#L608)，调用 `renderSnapshots()`，最后清理 fixture 并退出。它没有走正常启动下的后台引擎。fixture 使用仓库供应商声明，但为其替换拒绝执行的脚本、禁用默认账号创建，并使用 `example.invalid`、虚构授权和本地额度缓存；执行测试的确认回调拒绝真实调用。

[renderSnapshots()](../../Sources/TokenHUD/TokenHUDApp.swift#L199)把实际的 `SettingsCenterView`、导入面板、`FloatingView` 放进原生 `NSHostingView` / `NSWindow`，按场景渲染。`TOKENHUD_RENDER_ONLY` 是逗号分隔的**精确场景名**过滤器。`capture()` 布局并刷新窗口后，只执行该 fixture 窗口的 `screencapture -x -o -l <window-id>`；没有授权则记录不可用，不请求权限，也不使用全屏、坐标矩形或 ImageRenderer 伪截图。像素检查只能排除黑图、透明图和近空白图，不能替代人工验收。

### 当前工作树的截图命令示例

以下是由代码入口推导的**未来执行示例，本次未实跑**，也不是已找回的历史逐条终端记录。cwd 为仓库根目录，必须已能使用 swiftly；构建采用 [仓库要求的工具链](../../CLAUDE.md#L20)。不要为截图运行会安装或启动正常 App 的打包流程。

```sh
# cwd: 仓库根目录。仅在获准构建/截图的任务中执行。
swiftly run swift build

# 确认 .build/debug/QuotaNest 与旁边 SwiftPM 资源包来自同一次构建。
# 输出到独立目录；不覆盖历史公开截图。
QUOTANEST_RENDER="$PWD/.build/video-capture-en" \
TOKENHUD_RENDER_ONLY="accounts-1200-light,authentication-light,import-light,plan-1200-light,floating-style-card-light,floating-style-glass-dark,floating-style-compact-light,floating-style-list-light" \
.build/debug/QuotaNest -quotanest.appLanguage en

QUOTANEST_RENDER="$PWD/.build/video-capture-zh" \
TOKENHUD_RENDER_ONLY="accounts-1200-light,authentication-light,import-light,plan-1200-light,floating-style-card-light,floating-style-glass-dark,floating-style-compact-light,floating-style-list-light" \
.build/debug/QuotaNest -quotanest.appLanguage zh-Hans
```

语言取自 [AppLanguageSettings](../../Sources/TokenHUD/Localization.swift#L16) 的 `UserDefaults.standard`，键为 `quotanest.appLanguage`；上例用进程参数提供临时偏好，依赖 Foundation 参数域行为，尚未在本次运行验证。不能假定 `LANG` 环境变量会切换 App 文案。素材目录名 `zh-CN` 与 App 内部语言标识 `zh-Hans` 含义相近但不是同一个字符串。截图后先检查画面语言；不符合时停止，不改用户的全局偏好来试错。

### 公开素材的映射与整理边界

| 原生场景 | 视频使用的公开素材 | 整理要点 |
| --- | --- | --- |
| `accounts-1200-light` | [英文概览](../screenshots/en/overview.png)、[中文概览](../screenshots/zh-CN/overview.png) | 最终清单为 1200 × 860；保留顶部导航 |
| `authentication-light` | [英文认证](../screenshots/en/authentication.png)、[中文认证](../screenshots/zh-CN/authentication.png) | 清单为 1200 × 980；仅 fixture 文件引用 |
| `import-light` | [英文导入](../screenshots/en/import.png)、[中文导入](../screenshots/zh-CN/import.png) | 清单为 1000 × 708；显示演示候选，不扫描真实来源 |
| `plan-1200-light` | [英文计划](../screenshots/en/schedule.png)、[中文计划](../screenshots/zh-CN/schedule.png) | 清单为 1200 × 860；保留行为限制 |
| `floating-style-*-light` 与玻璃 `dark` | [四种英文 HUD 映射](../video-source/screenshots.json#L7)、[四种中文 HUD 映射](../video-source/screenshots.json#L19) | 使用真实四种样式，玻璃使用深色原生外观 |

截图清单中的尺寸与 `renderSnapshots()` 请求的内容尺寸可能因标题栏、系统缩放和后续整理而不同。仓库没有冻结从原始窗口 PNG 到每一张公开 PNG 的全部复制、裁边命令；不补造一个“完整截图脚本”。[capture-manifest.json](../screenshots/capture-manifest.json)记录最终资产信息，[screenshots.json](../video-source/screenshots.json)才是视频真正消费的路径。README 还包含用户提供的 HUD 图片，但该图片**没有出现在视频输入映射中**，本片无需复用它。

**缓存与重跑**：已有公开图片足以进入合成，无需再次碰 App。若只有导入画面有误，重新捕获 `import-light`、人工检查、替换相应语言的公开 PNG 后只重跑该语言。诊断命令即便返回成功，也可能没有有效 PNG；必须检查观察记录的 `image_written`、`capture_method`、`visual_status` 和实图。不要把旧缓存当成本次成功。

**隐私验收**：仅允许 fixture 窗口；画面中不出现真实账号、邮箱、私有工作区、个人目录、浏览器状态或钥匙。输出日志需先审查再分享，因为现有缓存可能含机器绝对路径；本复盘只引用仓库相对路径，不复制原始日志。fixture 假凭证也不应被当作可用凭证传播。

## 5. 阶段三：本地截图动效与合成

**输入**：[分镜](../video-source/storyboard.json)、[截图映射](../video-source/screenshots.json)、[模板](../video-source/template.html)、[品牌图](../video-source/app-icon.png)、[GSAP 库](../video-source/vendor/gsap.min.js)。**输出**：每语言独立 HTML、复制和裁剪后的素材、本地动画库、`hyperframes.json`、`meta.json`、`inputs.json`，位于忽略的构建目录。

关键函数与规则：

- [repo_file()](../video-source/build.py#L35)要求截图真实存在且解析后的路径位于仓库内，缺失或越界立即失败。
- [copy_asset()](../video-source/build.py#L64)记录原始素材 SHA-256。概览、认证、计划分别执行 `crop=1200:700:0:0`、`crop=1200:620:0:0`、`crop=1200:550:0:0`，去掉下部空白而保留左上导航；其余图片直接复制。这里记录的是原文件哈希，加裁剪参数，不是裁剪结果哈希。
- [build_composition()](../video-source/build.py#L94)按语言组装六段场景：0.24 秒淡入、截图从 `y:10, scale:0.99` 缓慢到 `y:0, scale:1.015`，前五段末尾 0.18 秒淡出；所有插入文案均经 HTML 转义。
- [hud_markup()](../video-source/build.py#L134)把四张原生 HUD 放在同一布局中，未强调项透明度 0.62；每隔 1.5 秒强调一个，而非把其他样式移出画面。
- [模板](../video-source/template.html#L9)使用本地 Arial 与系统回退；暗色渐变是视频画布样式，不能推导 App 有主题切换功能。时间线暂停并注册到 `window.__timelines`，由渲染器按时间推进；不依赖实时时钟播放。

cwd 为仓库根目录；以下是现有构建器的精确入口，**本次未执行**：

```sh
# 仅组装两种语言的 HTML 和本地输入，不渲染 MP4。
python3 docs/video-source/build.py

# 只重建一种语言的 HTML。
python3 docs/video-source/build.py --lang zh-CN
```

即使不带 `--render`，构建也会调用 FFmpeg 裁剪三类图片，所以仍需要 FFmpeg。图标已入库且由 [原说明](../video-source/README.md#L7)记载来自仓库品牌资产；最初转换命令未保留，直接复用已入库 PNG，不猜测转换工具。

**验收 / 停止**：检查截图没有拉伸、导航未被裁掉、中文无缺字、四 HUD 完整、每段留白适当；任何素材缺失、裁剪尺寸不符、画布文字溢出都先停在合成阶段。若只改版式或字幕，只重建 HTML 和预览，无需抓取新截图。

## 6. 阶段四：旁白、字幕与配乐的真实选择

本片**无旁白、无配乐、无音轨**。标题、副标题、底部注释是 [storyboard.json](../video-source/storyboard.json)中的 HTML 文字，经模板烧进每一帧，属于画内说明字幕；没有独立 SRT / VTT 轨道或语音对齐文件。压缩时显式 `-an`，[verify()](../video-source/build.py#L164)也拒绝有音轨的输出。

这里没有系统 `say`、TTS、音色挑选、音乐下载、音频混音、付费 API 或 AI 生图步骤。历史源说明提及另一项目早期采用过 `md-video` 与系统语音，但那是该说明的外部历史引用，不能迁移为本项目事实。需要配音或独立字幕时，应作为新的需求另行确认素材、授权、语言、时长和同步方案；通用 skill 不默认开启。

## 7. 阶段五：本地渲染、压缩和抽图

### 依赖与可证版本

| 依赖 | 证据 / 要求 | 本次确认程度 |
| --- | --- | --- |
| macOS / SwiftPM | [Package.swift](../../Package.swift#L1)声明 Swift tools 5.10、macOS 14+；[CLAUDE.md](../../CLAUDE.md#L20)要求 swiftly 工具链 | 未构建 App；swiftly 命令版本只读确认为 1.1.3，未查询实际所选 Swift 版本 |
| Python | [原说明](../video-source/README.md#L7)要求 3.10+；构建器使用标准库 | 本次 `python3 --version` 为 3.14.5；没有执行构建器 |
| Node.js | 原说明要求 22+，用于已有 HyperFrames CLI | 本次 `node --version` 为 22.22.1 |
| GSAP | [许可证头](../video-source/vendor/gsap.min.js#L1)为 3.14.2 | 直接读取本地入库源 |
| HyperFrames | [hyperframes_cli()](../video-source/build.py#L43)优先显式 CLI、PATH、已有 npm 缓存；缓存分支锁定 0.8.207 | 原说明记载已有 0.8.207；本次 PATH 无此命令，未扫描 npm 缓存或执行 CLI，不能称当前渲染可用 |
| 本地 Chrome runtime | [最终渲染日志](../video-source/build/final-render.log#L22)记录 HeadlessChrome 152.0.7977.30 | 仅历史缓存证据，不保证干净环境存在 |
| FFmpeg / ffprobe | 需 libx264、crop、PNG 编解码与 MP4 支持 | 本次两者版本均 8.1，构建信息含 libx264；仅用于版本和元信息查询 |

构建器不安装包；不使用 `npx` 临时拉取依赖。显式 CLI 和 PATH 分支并不自动核对 HyperFrames 版本，因此应先在获准范围内读取其本地 package metadata。Chrome runtime、字体和编译器插件仍需事先存在；禁用 telemetry 不等于操作系统级断网。依赖或 runtime 缺失时停止，报告缺少什么，不能自动下载。

### 完整导出入口

cwd 为仓库根目录，依赖和浏览器 runtime 必须已就绪；以下命令是**未来获准渲染时使用，本次未执行**：

```sh
# 两种语言，组装 + 9个预览时刻 + 渲染 + 转码 + 封面 + 编码帧 + 验证报告。
python3 docs/video-source/build.py --render --snapshot

# 只生成一种语言，减少无关重做。
python3 docs/video-source/build.py --lang zh-CN --render --snapshot

# 若CLI未在PATH，但已知已有本地安装位置：将占位路径替换为实际本地文件。
HYPERFRAMES_CLI="/path/to/existing/node_modules/hyperframes/bin/hyperframes.mjs" \
  python3 docs/video-source/build.py --lang en --render --snapshot
```

[ENV](../video-source/build.py#L19)为 HyperFrames 子进程设置 `HYPERFRAMES_SKIP_SKILLS=1`、`HYPERFRAMES_NO_TELEMETRY=1`、`DO_NOT_TRACK=1`。这表示直接用 CLI，不安装或调用全局 skill。最终模板引用本地库和图片；[早期 smoke 日志](../video-source/build/smoke.log#L17)曾记录自动拉取 Inter 字体，最终模板已经改为本地 Arial，因此不能照搬早期 smoke 合成以声称离线。

`render()`内部在每语言的构建目录运行：

```sh
# cwd: docs/video-source/build/<language>
# <local-hyperframes> 代表已验证的本地可执行命令或 node + 本地mjs。
<local-hyperframes> snapshot --at 2,6.5,11.2,15.5,18.7,20.2,21.7,23.2,25.5 --no-end -o review
<local-hyperframes> render -o <absolute-intermediate-render.mp4> \
  --fps 30 --crf 20 --workers 2 --no-best-effort --strict --quiet
ffmpeg -hide_banner -loglevel error -y -i <absolute-intermediate-render.mp4> \
  -an -c:v libx264 -preset medium -crf 21 -pix_fmt yuv420p \
  -r 30 -movflags +faststart <absolute-final-video.mp4>
ffmpeg -hide_banner -loglevel error -y -ss 2 -i <absolute-final-video.mp4> \
  -frames:v 1 -update 1 <absolute-poster.png>
```

尖括号行是解释内部调用参数的占位模板，不可原样粘贴；直接使用上方构建入口可获得真实绝对路径。中间视频先以 CRF 20 渲染，最终用 CRF 21 / medium 再编码，意图是兼容性、体积与网络起播。最终视频会被 `-y` 覆盖，因此重跑前确认目标是这份片子的交付位置，不要误指用户其他媒体。封面与九个编码帧都从最终 MP4 抽取，而不是只截预览 HTML。

**增量限制**：构建器支持按语言重跑和仅预览；没有实现按内容哈希跳过构建或按场景独立导出。输入哈希用于溯源，不是缓存命中机制。`--lang` 单语言渲染仍会覆盖 [verification.json](../videos/verification.json)为该次语言列表；不要据一个新报告宣称两种语言都新验收过，需保留旧证据或最后明确运行双语验证。

## 8. 阶段六：验证、视觉验收与发布引用

### 媒体检查

[verify()](../video-source/build.py#L149)读取实际 ffprobe 流，约束：24–29 秒、少于 15,000,000 bytes、H.264、yuv420p、1440 × 900、30 fps、无音轨；读取前 1 MB 检查 `moov` 出现在 `mdat` 前，并计算 MP4 SHA-256。它的时长范围比本片目标 27 秒宽，交付时仍应与分镜目标对照；它也不自动检查所有输入哈希是否仍匹配、不执行完整解码或视觉判断。

本次父层于 2026-11-09 另以本地 Python 只读校验 [verification.json](../videos/verification.json) 内的成品及 `inputHashes` 共 22 条 SHA-256，全部重新计算并匹配，0 项不一致；同时确认两份新增文档的本地 Markdown 链接目标存在、无未解析的敏感信息占位符。这些结果没有涉及重新截图、渲染、完整解码、faststart atom 探测或外部发布。

本次调查执行的两个 ffprobe 命令如下，cwd 均为仓库根目录；没有写入文件：

```sh
ffprobe -v error \
  -show_entries format=duration,size:stream=codec_type,codec_name,pix_fmt,width,height,avg_frame_rate,nb_frames \
  -of json docs/videos/quotanest-demo-en.mp4
ffprobe -v error \
  -show_entries format=duration,size:stream=codec_type,codec_name,pix_fmt,width,height,avg_frame_rate,nb_frames \
  -of json docs/videos/quotanest-demo-zh-CN.mp4
```

完整解码帧数是[历史实际检查](../video-source/verification.md#L18)，未来变更视频后可按该方式重做；本次只核容器帧数，未重复解码：

```sh
# cwd: 仓库根目录。未来复验示例，本次未执行。
ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames,r_frame_rate -of json \
  docs/videos/quotanest-demo-zh-CN.mp4
```

### 视觉检查

[历史视觉记录](../video-source/verification.md#L30)覆盖九个合成时刻与每语言六段实际编码帧。本次只打开现存的[英文联系表](../video-source/build/en/review/contact-sheet.jpg)和[中文联系表](../video-source/build/zh-CN/review/contact-sheet.jpg)，确认六段叙事、双语、品牌、四 HUD 与行为限制在缓存画面中可见。未播放完整视频，也未逐帧复核现存编码输出，不能把联系表检查等同完整播放验收。

未来每次修改后只做一轮受影响检查：

1. 预览时间点固定为 2、6.5、11.2、15.5、18.7、20.2、21.7、23.2、25.5 秒；四个 HUD 强调阶段都必须覆盖。
2. 先查合成联系表：截图真实、文字不溢出、双语对应、导航未丢失、底部备注不被遮挡。
3. 再查最终编码帧：画面无黑屏、无缺图、无缺字、字号可读、四 HUD 都在画面内、淡入淡出边界没有叠字和闪帧。至少正常播放一次验证转场节奏。
4. 检查假数据标识、只读导入、窗口不保证开启的语义；不得把演示当成真实供应商连通或长期同步验收。
5. 小窗/移动端若难读，记录目标场景限制；只有用户需要移动端版本时再做新的近景剪辑，不默认扩大本次任务。

### 发布实际到哪一步

当前[英文 README](../../README.md#L32)和[中文 README](../../README.zh-CN.md#L32)都有附件播放器 URL，并保留仓库 MP4 的下载链接和制作源入口。Git 提交 `476a035` 证明引入引用的变更；[附件记录](../videos/github-attachments.json#L1)还保存了两语言的 URL、对应仓库 MP4、与媒体验证记录相同的 SHA-256、`storage_status: 204`、`preview_duration_seconds: 27` 和 `preview_ready_state: 4`。这些是历史发布/预览核验记录，不是本次发起请求得到的状态；本次没有打开外部 URL，因此不能保证远端当前可播放，也没有重新下载附件校验哈希。

[原制作说明](../video-source/README.md#L60)记录了参考项目采用浏览器草稿上传附件并获取 Markdown 的历史办法；本次不访问该浏览器状态，也不据此断言 QuotaNest 的附件是用同一套具体工具上传。QuotaNest 的具体上传工具和逐条上传命令在已检查的本仓库证据中不足。未来发布是单独权限边界：先交付本地视频、封面、脚本/分镜、命令和验证记录，再在明确授权后上传或更新外部页面；无需为了本地交付登录。

## 9. 失败定位与最小重跑

| 现象 | 本项目依据与定位点 | 最小处置 / 停止条件 |
| --- | --- | --- |
| 系统 `swift build` 链接失败 | [CLAUDE.md](../../CLAUDE.md#L20)记录 CLT Swift 与 ManifestAPI ABI 不匹配 | 用仓库要求的 swiftly；不为文档任务构建、升级或安装工具 |
| 没有截图、截图是黑图或旧图 | [capture()](../../Sources/TokenHUD/TokenHUDApp.swift#L508)无权限就记不可用；[imageQuality()](../../Sources/TokenHUD/TokenHUDApp.swift#L562)拒绝无效像素 | 查观察记录和准确场景；权限不可用即停，不全屏补拍；只重捕受影响场景 |
| 英文视频用了中文 UI | [Localization.swift](../../Sources/TokenHUD/Localization.swift#L31)读 App 偏好，视频语言只选择已有图片 | 先核截图语言与映射；只替换错误语言资产，不以更改字幕掩盖 |
| 裁图失败或截掉导航 | [copy_asset()](../video-source/build.py#L73)固定宽 1200 和左上原点 | 核实际源图尺寸，按该场景修参数；只重建合成/预览，不盲目重录 |
| HyperFrames 找不到 | [hyperframes_cli()](../video-source/build.py#L43)无 PATH 且无指定版本缓存即失败 | 报告依赖缺失；可用时指定已有本地 CLI；不自动 `npx` 下载 |
| 渲染尝试网络取字体 | [早期 smoke 日志](../video-source/build/smoke.log#L17)与[最终 local 字体](../video-source/template.html#L9)存在明确差异 | 停在合成；使用最终本地字体模板并核 runtime 已备妥，不把遥测关闭当成断网保证 |
| 只看到预览好看，MP4不对 | [render()](../video-source/build.py#L190)专门抽实际编码帧 | 对比对应时刻；若中间 MP4正常，只重转码和抽图；不要重新获取全部素材 |
| 体积/帧率/像素格式不合格 | [verify()](../video-source/build.py#L158)明确断言并使流程失败 | 查最终 FFmpeg 命令与输入；调整后只做受影响编码和验证 |
| 单语言运行后另一语言“消失”于报告 | [main()](../video-source/build.py#L221)重写整个报告 | 说明报告范围；保留旧证据，最终按需要补双语验证 |
| 干净克隆没有构建缓存 | [gitignore](../video-source/.gitignore#L1)忽略 build 与 pycache | 缓存不是源；从入库截图与源开始；缺 Chrome/CLI 停止，不宣称一条命令可在任意机器执行 |

现存[最终日志](../video-source/build/final-render.log)和 `.hyperframes` 缓存可辅助定位；它们是忽略文件，包含机器路径，可能不会随克隆出现。文中这些缓存链接只对应本次确实存在的证据，分发时应带上必要的脱敏记录或明确缺失，不将缓存设为通用 skill 的必需依赖。

## 10. 从这次制作提炼出的最小通用范式

可复用的是“查清已有链 → 核事实 → 隔离演示素材 → 冻结输入与时间表 → 最小合成 → 兼容导出 → 真实媒体和视觉验收 → 本地交付 / 授权发布”。真正通用的单位是素材、叙事、命令和验收边界，而不是某个视频框架。

原生项目优先复用它的 fixture 窗口，Web 项目优先复用本地 demo 路由和固定浏览器视口，CLI 项目优先复用隔离输入和确定性终端画面。能用静态截图和简单转场讲清楚，就不增加 AI 画面、配音、音乐或复杂动效；只有连续操作本身是讲解对象时再安排录屏。

通用 skill `evidence-based-product-video` 把项目名、仓库根、观众、用途、时长、语言、宽高、fps、主题、素材策略和输出位置都改为输入变量，并把安装、网络、真实账号、付费请求和发布列为独立授权边界。该 skill 已按用户要求移至 Claude Code 的用户级 skills 目录；本指南继续保留项目特定的制作证据与复现说明。
