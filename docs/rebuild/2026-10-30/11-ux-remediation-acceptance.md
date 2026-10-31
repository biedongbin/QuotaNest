# 本轮 UI 整改验收记录

日期：2026-10-30。用户明确要求整体整改并授权实施，主线程制定以下 A—F 实施约束；具体布局、控件和窗口策略不声称用户逐条确认。本文维护本轮真实状态，不代表整个 App 无 Bug。

状态只使用：**未验**（尚无匹配证据）、**通过**（注明版本、动作或命令及观察）、**受限**（说明缺少的条件与可证明边界）。发现失败时先记录具体失败并修复，未复验不得标通过。

此前 HUD／导航证据见 [10](10-hud-navigation-verification.md)。GPT 周期／浮窗修复已安装 `519d2ff-dirty`，证据位于 `/var/folders/_x/1lcyw8ss32sgds54r98dqmbw0000gn/T/tokenhud-gpt-floating-verification-arp8anw0/delivery-result.json`；该证据只证明上一轮两个问题，不能覆盖本轮 UI。

## 当前执行约束

- 总览按供应商分组，统一全宽单列账号面板，搜索、组头、面板使用相同内容右边界。窗口 640／900／1200 点宽均可用，不靠提高最小宽度隐藏问题。
- 查询、配置、供应商启停直接可见；菜单栏及悬浮窗共用展示偏好，HUD 展示偏好独立且明确可操作。更多只放低频／删除，右键与可见按钮复用相同动作。
- 详情账号标题仅一次，品牌、认证方式和状态分别表达一个含义。无真实 quota 时不画空 5h／周／月三卡；未查询、错误都能看到下一步动作。
- 配置页含“查询额度”和“发送测试调用”，支持当前草稿，发送前可见目标和消费确认；查询与调用独立反馈，测试不隐式保存。自动任务页只管理每日计划、开关、下一执行与最近结果。
- 设置中心显示时为 `.regular` 且主窗可 key，系统可切换；关闭后按统一策略回到菜单栏状态，X／Esc 与退出一致。单例、位置记忆成立，浮窗仍不抢焦点。
- 自然操作覆盖空态、多供应商、同组多账号、长名称、真实单周／5h＋周双窗、错误、停用、表单字段、搜索与导航；修复同链明显缺口，不扩供应商范围。

## 分项可观察验收

| 项 | 动作与必须观察的结果 | 证据要求 | 状态 |
| --- | --- | --- | --- |
| A1 对齐与宽度 | 640／900／1200 宽查看总览；搜索、组头、账号面板右边齐，无裁切、孤立空白或随机卡宽，窄宽操作可换行 | 实际 SettingsCenterView 的原生明暗截图，辅以窗口／命中区域几何 | 通过：主线程目视三宽及深色图；固定 184 侧栏＋双侧 20 内距，主列可用宽 415／675／975 |
| A2 数据密度 | 同组至少两个账号、长显示名、多供应商、单周及双窗口均能读清 | 同一脱敏 fixture 的宽度矩阵，主线程目视 | 通过：同组多账号、长名、单周／双窗及错误／停用截图经主线程目视 |
| B1 常用动作 | 从总览直接查询、配置、启停；展示到菜单浮窗／HUD 的偏好能操作且结果可见 | 隔离模型／按钮动作证据，不由截图推断 | 通过（有限范围）：查询／启停／展示入口可见；实际配置→编辑→取消测试事件通过，保存与零调用由隔离模型回归证明；未实际拨动全部真实账号开关 |
| B2 更多与右键 | 更多仅低频／删除；右键与可见入口产生同一动作，禁用原因可见 | 动作映射与原生菜单证据，各自注明范围 | 受限：共享动作实现与低频菜单静态核对完成；未执行真实桌面右键链 |
| C1 详情结构 | 进入同账号详情，标题仅一次；品牌／认证／状态无重复含义 | 额度／配置／自动任务截图及导航观察 | 通过：640 配置及 1200 单周详情目视，显示名标题一次，品牌／认证／启停分义 |
| C2 无数据恢复 | 未查询和错误各有明确原因及查询／配置下一步，不显示假三空卡 | 未查询／错误脱敏场景截图与动作观察 | 通过：error-detail／unqueried-detail 图无假三空卡；quotaRowsSwitchesToWindowsWhenPresent 正式通过 |
| D1 配置即测 | 配置页可查询及发送当前草稿测试；显示目标／消费，独立结果且不保存 | fake executor／URLProtocol，临时文件前后比较，真实 POST 为零 | 通过：固定测试入口与滚动后持续结果目视；native-actions 三步确认取消零调用；当前草稿执行参数／不保存由正式模型回归证明 |
| D2 保存与计划隔离 | 普通保存不开请求；测试不改计划；自动任务页仅每日计划／开关／下一执行／结果 | 隔离状态测试、文件与请求计数，加页面观察 | 通过：保存留配置零请求、独立 A/B key、new plan 拒绝、new test 结果保存迁移、pending time guard 命名回归全部正式通过；自动任务图无手动发送 |
| E1 系统窗口 | 打开为 .regular、主窗可 key；关闭／重开单例与位置一致，浮窗不抢焦点 | 真实 App activation policy／窗口属性与原生隔离测试 | 通过（证据分层）：同源码安全 App 主循环 .regular＋key；窗口 runtime 单项曾执行通过（整体 filter 缺尾标）；安装 App .regular、主窗及浮窗可见，跨进程 key 未直接读取 |
| E2 桌面切换 | 系统 Cmd-Tab 实际按键可切回设置中心 | 真实桌面按键；若无权限则记受限，policy 不冒充按键 | 受限：未实际按桌面 Cmd-Tab，不以 activation policy 或截图代替物理按键 |
| F1 自然流程 | 总览→搜索／清除→详情→配置→测试→计划→返回／全局页；长名、空态、停用不阻塞 | 记录实际按钮事件或明确状态测试范围，不能直接 navigate 冒称点击 | 通过（限已执行段）：真实安全 App 内配置→编辑→发送测试→确认取消，草稿保留且凭证未写；搜索／导入完整自然点击链未执行，不外推全链 PASS |
| F2 最终安装 | 源码冻结，构建／测试／GPT27通过，独立 review，无阻断后备份安装 | 版本、签名、实际运行路径、配置保护与安装后关键行为 | 通过：最终默认 175 项／20 套件正式通过，GPT27 通过；519d2ff-dirty 已安装，严格签名通过，配置保护无差异 |

## 截图矩阵

截图来自实际 SwiftUI `SettingsCenterView` 的 `NSHostingView`／`NSWindow`，不使用 HTML 原型代替。每张记录内容尺寸、外观、场景；几何只辅助目视，不单独宣布布局通过。

| 场景 | 640 宽 | 900 宽 | 1200 宽 | 外观与内容 |
| --- | --- | --- | --- | --- |
| 总览多账号 | 通过 | 通过 | 通过 | 明／暗；多供应商、同组多账号、长名称、单周、双窗口、错误、停用 |
| 配置与测试 | 通过 | 未验（未单独截图） | 通过 | 明／暗关键页；表单、查询与测试动作、结果、保存可达 |
| 自动任务 | 通过 | 未验（未单独截图） | 通过 | 明／暗关键页；每日计划与下一执行，无隐藏手动测试 |
| 额度详情 | 通过：错误／未查询 | 未验（未单独截图） | 通过：单周 | 单周实际卡数；错误／未查询有下一步，无假三空卡 |
| 空总览／无搜索结果 | 通过：无搜索结果 | 未验（未单独截图） | 通过：空总览 | 清搜索、添加／导入入口自然可达 |

## 隔离与执行顺序

1. 诊断模式先于生产引擎构造分流；复用 `DiagnosticFixture`，所有 settings／HUD／日志／账号模板位于临时目录，defaults 独立，绝不调用 `engine.start()` 或真实来源扫描。
2. 查询脚本与模型调用只用假脚本／fake URLProtocol／假凭证，不请求真实供应商、不刷新 token；不得通过打开页面、保存、切 tab 或导入发送模型调用。
3. 保存、草稿测试、每日计划分别记录：保存只写配置；测试只产生独立结果；计划只按已保存授权条件执行。测试前后比较临时配置与请求计数。
4. 两作者及渲染入口冻结后，由唯一执行者运行 swiftly 构建／完整测试一次、GPT27回归及安全截图；作者补改先通知并序列化，避免边改边构建。
5. 主线程目视检查 640／900／1200 与明暗关键页；原生按钮事件、状态模型、截图、窗口 policy 各自说明证据边界。旧 NSEvent harness 缺正式完成标记的结果不升级成 PASS。
6. 独立有限 review 后备份旧 App／替换脚本，按项目打包安装。真实 settings、envs、凭证、旧备份、供应商启停／计划与用户偏好作摘要保护；允许本次用户明确操作造成的窗口位置变化，其他差异必须核实。

## 本轮证据登记

证据目录：`/var/folders/_x/1lcyw8ss32sgds54r98dqmbw0000gn/T/tokenhud-ux-verification-qcveqt63/`。以下文件均为本轮实际产物，临时目录保留供审阅。

| 对象 | 本轮版本／路径／观察 | 状态 |
| --- | --- | --- |
| 安全渲染 | `screens/` 共 17 张；`render-observations.json` 记录实际尺寸；三宽总览明暗、配置固定测试入口、滚动后的 callGroup 常驻结果、计划、单周、error、未查询与空态经主线程目视 | 通过：布局与状态截图范围 |
| 最终构建与默认测试 | `swift-full-suite-delivery.log`：175 tests／20 suites 正式完成；`gpt-regression.log`：27／27；先前失败日志保留，不覆写为通过 | 通过 |
| 关键数据保护回归 | `savingOrClearingQueryKeyPreservesIndependentCallKey`、`updateKeyThreeIntentsPersist`、`newPlanCancellationKeepsDraftAndCreatesNoAccount`、`newDraftResultMovesToSavedAccountAndRunningTestBlocksSave`、`pendingTimeRequiresDiscardConfirmation`、草稿当前参数、确认取消、保存留配置零请求均正式通过 | 通过：隔离状态回归 |
| 真实 App 内按钮事件 | `screens/native-actions.json`／`native-app-diagnostic-result.json`：真实 NSWindow 与 NSEvent 三步使 detail/config、draft、confirmations=1 依次改变，calls=0、auth unchanged、window key、regular、completed／pass 均 true | 通过：安全 fixture 内配置→编辑→取消测试；不证明桌面输入 |
| Swift Testing UI opt-in | `window-runtime.log` 曾记录实际窗口 test passed，但 filter 无正式 run 尾标；`ux-native-click.log` 早期定位失败，修正后 `ux-native-final.log`／`window-runtime-final.log` 进程提前结束，不能因 exit0 记 PASS | 受限，保留原日志；不再扩展 harness |
| 安装包 | `/Users/biedongbin/Applications/TokenHUD.app`，`519d2ff-dirty`，PID 73465；`installation-result.json` 与 `package-final.log`，严格签名通过；无 commit／push | 通过 |
| 安装窗口 | `installed-window-result.json`：真实 App .regular，主窗口 1127×600 可见，浮窗 layer3 整体在可见屏幕；跨进程主窗 key 未读，检查时终端已在前台；key 证明来自同源码安全 App 内窗口 | 通过：policy／窗口几何；桌面 Cmd-Tab 未实按 |
| 配置保护／回滚 | `protection-after-deployment.json`；settings、envs、provider auth、Codex auth、旧备份与供应商启停／计划偏好不变；窗口位置允许随显式打开更新。旧 App 和替换脚本在 `rollback/` | 通过：见 `protection-after-deployment.json` 与 `delivery-result.json`，真实受保护配置无差异 |

已修复的同链缺口包括品牌组头误用账号名、保存独立调用 key 被查询 key 覆盖、清查询 key 后再次编辑误回填调用 key、新建计划绕过确认、新建测试结果保存后丢失、未添加 timeInput 不计 dirty。具体当前行为以最终测试和代码为准，不由截图推断凭证写入或消费边界。

截图、状态回归、真实 App 内事件、系统窗口元数据与桌面按键分别记录；不宣称全部自然操作链或整个 App 无 Bug，不把未执行范围交给用户代验。

## 后续入口一致性与固定工具栏交付

同日追加，证据目录：`/var/folders/_x/1lcyw8ss32sgds54r98dqmbw0000gn/T/tokenhud-entry-consistency-kaqt42wj/`。详情共用启用／停用入口、卡片非控件主体按钮、独立控件命中区域、草稿主门控同步及停用旧数据文案已实现；搜索固定 280×32、筛选五个 72×30 chip，宽窗同行、窄窗两行，最新 640／1200 截图位于 `screens/`。

- 正式回归：`full-suite-final.log`／`full-suite-final-result.json`，177 项／21 套件通过；新增 `AccountControlTests` 的草稿启停同步与消费计划恢复取消两项通过。测试使用显式临时显示偏好，不启动引擎。
- 安装：`installation-result.json`／`package.log`，`519d2ff-dirty`、PID 81145、严格签名通过；原浮窗恢复，安装前真实主窗不可见，未强行打开。旧 App／脚本备份在 `rollback/`。
- 原生事件限制：早一布局运行观察 12 步中的 11 步通过；最终布局 `diagnostic-result.json`／`screens/entry-actions.json` 为 **pass=false**，固定坐标未全部命中，不能称最终事件链通过。保留失败记录，未继续扩展驱动。
- 文件保护：settings、envs、provider auth、Codex auth 和旧备份内容未变；`local.tokenhud` 稳定偏好汇总哈希发生变化，真实 App 期间持续被用户使用，基线只存汇总哈希，无法归因到具体 key。`protection-after-deployment.json` 与 `delivery-result.json` 因此保留 **pass=false**，不声称所有启停／显示偏好均证明未变，也不擅自回滚用户当前偏好。
- 不新增 commit／push，不操作真实模型调用，不为测试启用真实停用供应商。上述诊断与偏好证据限制需与代码实现、正式回归和安装成功分开说明。
