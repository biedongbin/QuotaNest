# S5 现有程序差距审计（08）

日期：2026-10-30。分支 `feature/provider-manager-v2` @ 846ad91。规范基准：[01](01-requirements-outline.md)/[02](02-technical-outline.md)/[04](04-global-requirements.md)/[05](05-global-technical.md)/[06](06-ui-flows-and-acceptance.md)（FR-01~10、NFR-01~05 稳定编号）。本文只审计与定差距，不改代码；复用/修复/重写由主线程裁决。

## 0. 测试基线

- 命令：`export PATH="$HOME/.swiftly/bin:$PATH"; swiftly run swift build && swiftly run swift test`
- 结果：`Build complete!`（0.14s，缓存命中）；**`Test run with 75 tests in 12 suites passed`**（4.16s），exit 0。
- 备注：项目 CLAUDE.md 写"32 个测试"已过期，实际 75。全部通过仅证明既有行为自洽，不证明符合目标规范。

## 1. 总体结论

现有程序是一个以 **slug 为主键、单时间戳缓存、无操作版本** 的插件式实现：UI 骨架（设置中心三 tab、草稿 guard、单例窗口、右键菜单、悬浮窗）与 04/06 的交互基线大体重合，但 **数据正确性基础设施（身份版本体系、快照时间语义、回包核对、调度持久去重、导入事务与同源去重）与 05 的契约几乎整体缺失**，且存在多处"点击即隐式消费模型额度"的路径。按 P0/P1/P2 分批修复（§5），不需要全量重写：插件扫描/manifest 声明式架构、UI 框架、导入扫描器可保留，核心数据层需重建。

## 2. FR 逐条差距表

格式：现状(file:line) → 符合项 / 差距(违背子号) / 修复规模（小=<1 天，中=1-3 天，大=>3 天）。

### FR-01 账号创建、编辑、删除与多实例

- 现状：slug 即身份（`PluginProvider.id = slug`，Models.swift:174-176）；改名只写 displayName、slug 不变（SettingsModel.swift:539-580），同模板多实例靠 `-2` 后缀（SettingsModel.swift:493-499）；删除有确认弹窗、清插件目录+trash auth 文件（SettingsModel.swift:648-664）。
- 符合：FR-01.2 显示名可重复且不改文件名、FR-01.3 多实例隔离（配置/缓存按 slug 分文件）、FR-01.1 空态模板目录+导入入口。
- 差距：
  - **无 App 内稳定 UUID、无 providerId 独立、无 accountRevision/queryConfigRevision**（05§3 全缺）→ 迟到回包只能按 slug 提交，无法判版本（见 FR-05.3）。违背 05§3、FR-01.6 回包按 accountId+revision 丢弃。**中**。
  - 删除后 cache 文件（`.{slug}-usage-cache.json`）与 envs.json 条目残留，HUD 可能继续显示已删账号（SettingsModel.delete:648-664 未清 cache、未摘 envs）。违背 FR-01.6"仅清 App 自有凭证/缓存"。**小**。
  - 删除不取消在途查询（无任务取消机制，仅靠 reloadRegistry 后 apply 的 slug 查不到丢弃——碰巧挡住 states 内提交，但 forceRefresh 对停用账号仍写缓存，DataEngine.swift:324-341）。违背 FR-01.6"取消尚未发送任务"。**中**（随 op 体系一并建）。
  - FR-01.4 合规大半：整体草稿跨 tab 保留（Draft/values 单实例，SettingsModel.swift:82-94）、运行记录不进草稿。但 FR-01.5"合法不完整可保存并标未配置"未实现——key/url 为空直接拒绝保存（SettingsValidation.configErrors:30-45 只有报错分支，无"保存为未配置"路径）。**中**。

### FR-02 凭证配置与只读 CLI 来源

- 现状：authStyle 三态 apikey/local/oauth（Models.swift:41）；local 型只读展示、表单无编辑入口（ConfigTabView.swift:31-35、DraftFormView.swift:148-158）；key 有 SecureField+显隐（DraftFormView.swift:131-147）。
- 符合：FR-02.1 区分 API Key 与本机 CLI 来源、FR-02.4 CLI 来源不写回、FR-02.5 无假登录按钮（oauth 仅文案）。
- 差距：
  - **FR-02.2/02.3 空 key 语义相反**：现状空 key = 校验错误拒存，规范要求空框=保持原值、替换/清除是独立意图+确认。现 update() 直接 `cfg.queryKey = values.key`——用户清空输入框保存即误清 key（SettingsModel.swift:544，且校验先行挡住，等于两个方向都没实现）。**中**。
  - FR-02.6/02.7 无身份字段与调用凭证分离、无 token 轮换"旧值标待验证"（依赖版本体系缺失）。**中**。
  - 凭证文件权限：UI 文案称"600 权限"（DraftFormView.swift:145），PluginGenerator 写文件未显式 chmod 0600（见 FR-10）。**小**。

### FR-03 官方额度查询与标准展示

- 现状：查询走 provider 脚本（fetch.sh→mjs），stdout 解析为 UsageCache，失败保留旧值+stale 标记（DataEngine.apply:402-420）；已用百分比直取、缺失显示"—"不造 0（QuotaTabView.quotaCard:94-154）；旧值卡降级不画进度条（QuotaTabView:122-127）。
- 符合：FR-03.2 已用直取、FR-03.4 缺失不显示 0%、旧值标识（"旧值"徽章）、FR-03.7 部分（脚本内业务校验，2xx 空数据返回 nil）。
- 差距：
  - **失败推进时间戳**：apply() 失败分支 `old.generatedAt = now`（DataEngine.swift:414，注释自认是为防 10s timer 重刷的补丁）——generatedAt 是唯一时间戳，被当成 attempt 时间用，原始采集时间被覆盖丢失。无 snapshotCapturedAt、无 lastSuccessAt 持久（SettingsModel.lastSuccess 仅内存，SettingsModel.swift:230）。违背 FR-03.8/FR-09.2/05§4"失败不推进最近成功时间"。**P0，中**。
  - **固定三窗口**：UsageCache 硬编码 fiveHour/sevenDay/monthly（Models.swift:140-165），UI 恒画三卡（QuotaTabView:86-92），无动态窗口列表、无 used/remaining/limit/period/单位/金额语义。违背 FR-03.5/03.6、05§4。**大**（缓存契约+脚本输出+UI 三处）。
  - resetsAt 过期仅倒计时消失（HUDFmt.resetCountdown:18-25 返回 nil），未标"待更新"语义，但也未清零——部分符合 FR-03.8；缺"待更新"文案。**小**。
  - stale 判定 = `now-generatedAt > interval`（HUDFmt.isFresh:28-31），与错误/身份无关；interval 默认 60s（Models.swift:34），非规范 300s 默认/60-3600 范围/provider 下限优先。**小**。

### FR-04 可控手动模型调用

- 现状：testCall 有 NSAlert 消费确认（SettingsModel.swift:622-629）；running 集合防同账号重复点击（SettingsModel.swift:630）；结果 toast 展示（SettingsModel.swift:644）。
- 符合：FR-04.1 确认弹窗含消费与协议说明、FR-04.2 查询按钮不触发调用（query 与 testCall 分离）。
- 差距：
  - **send() 无超时**（URLRequest 默认 60s，RefreshTrigger.swift:65-78）、网络错误直接报 localizedDescription——**结果不确定（可能已消费）未表达**。违背 FR-04.4/04.5。**小**。
  - 成功判定 = HTTP 200 即"测试调用成功"（RefreshTrigger.swift:69-71 只拼 body 前缀展示，SettingsModel.swift:644 按 err==nil 判成功）——无业务结构校验；且 200 空 body 返回 nil 被当**成功**（err==nil）而规范要求说明。**小**。
  - max_tokens 50、默认 prompt"test，收到回复1"（RefreshTrigger.swift:31-35、ProviderConfig.swift:18）vs 目标建议"只回复OK"+16。**小**。
  - FR-04.7 缺"用当前草稿发送测试调用"：现按钮是"保存并发送测试调用"且要求先保存（DraftFormView.swift:232-240），无草稿目标测试、无"不隐式保存"。**中**。

### FR-05 自动额度查询

- 现状：10s timer + isFresh 快照筛 due（DataEngine.start:132-138、refreshNow:307-319）；disabledSlugs 独立于 triggerDisabledSlugs（DataEngine.swift:78-80）；手动查询对停用账号仍可用（forceRefresh:321-341）。
- 符合：FR-05.1 部分（开关独立持久）、FR-05.2 后半（关闭不禁用手动）、FR-05.7 部分（失败不触发模型）。
- 差距：
  - **无 opId、无合并键、无并发上限**：refreshNow 对全部 due 家并行 TaskGroup（DataEngine.fetch:378-393，无全局 3 限制）；手动 forceRefresh 可与 timer 查询同账号并发（引擎层无每账号 1 执行位；UI running 集合只挡双击）。违背 FR-05.3。**中**。
  - **无 429/Retry-After/401 不重试策略**：引擎不感知 HTTP 语义（脚本内部自理，引擎只见 stdout/退出码）；无暂停窗口、无 max(interval,60s) 兜底。违背 FR-05.5。**中**。
  - **due 语义偏离**：due = generatedAt+interval（失败也被推进，见 FR-03），非"保存生效时刻+新间隔"；间隔变更无独立 due 计算。违背 FR-05.2。**中**（随时间戳体系重建）。
  - **保存触发查询**：SettingsModel.save() 成功后 `Task { await engine.forceRefresh(slug) }`（SettingsModel.swift:470）——直接违背 FR-05.2/05§5"保存不发请求、不排查询"。**小**（删一行+补说明，但要重定 due）。
  - 睡眠唤醒：无显式唤醒处理，靠 10s timer 恢复后 isFresh 筛选——行为上近似"每账号最多补一次"，但无散开、无并发约束。违背 FR-05.6。**小**。

### FR-06 定时模型调用

- 现状：scheduleTimes 存 auth 文件（ProviderConfigStore.write:124-129）；严格 HH:MM 校验+去重（SettingsValidation:8-14、48-64）；两开关独立；TriggerTab 只读展示执行时间。
- 符合：FR-06.2 时间格式校验、FR-06.1 部分（新建草稿 autoTrigger=false，SettingsModel.swift:388）。
- 差距（本 FR 是差距最重区）：
  - **去重键内存态且跨天误杀**：`lastScheduledTrigger: [slug: HH:MM]` 仅内存（DataEngine.swift:187），且键为 HH:MM 无日期——**单时刻账号当天触发后，值停在 "09:00"，次日 09:00 判 `== hhmm` 直接跳过**：每日一时刻的账号在 App 不重启的情况下只触发一次即永久静默。违背 FR-06.2/06.3。**P0，小-中**（换持久键 accountId+localDate+HH:MM）。
  - **无持久 started/terminal 登记**：重启落在已触发分钟内会再次触发（内存键清零）→ 跨重启重复消费；无 skipped 记录（睡眠错过静默漏发）。违背 FR-06.3/06.4、05§7。**中**。
  - **无 planRevision/targetFingerprint/发送前版本核对**：保存改时间/目标后，cachedSchedules 在 reloadRegistry 才重建（DataEngine.swift:233-238）——若旧分钟事件已在飞 Task 中，无复核。违背 FR-06.7/06.8。**中**。
  - **无并发位**：checkSchedules 直接 `Task { RefreshTrigger.trigger }`（DataEngine.swift:201-203），不查 running、无每账号 1/全局 2、无 busy skipped。违背 FR-06.6。**中**。
  - **启用无消费确认**：autoTrigger 开关随草稿保存即生效，无"启用需一次清楚的目标与消费确认"。违背 FR-06.1。**小**。
  - DST/改时区：无处理（无本地日期键即无从谈起）。违背 FR-06.5。**中**（随持久去重键解决）。

### FR-07 三源导入

- 现状：三源 adapter 只读（ProviderImporter.swift:33-215）；扫描 8s 超时+可取消、超时/失败/空三态区分（ImportCenterSheet.swift:102-157）；不支持的行保留+原因（unsupportedReason）；停用项默认不勾（apply:174）；逐行结果+失败重试不重复成功项（importSelected:239-267）；源账号标识脱敏（isAccountId/maskAccount）。
- 符合：FR-07.1/07.2 大部、07.3、07.7（重试仅失败项）、07.8 部分（不反写源、计划默认无时刻）。
- 差距：
  - **查重按显示名**：`p.manifest.fullName == c.name` 判"已存在"（ImportCenterSheet.swift:190-194）——与规范相反：**同名不算重复**（FR-07.5），且无 origin(sourceName, stableSourceRecordId) 持久——同源再导不识别已导项，uniqueSlug 加 `-2` 造重复账号（ProviderImporter.swift:296-304）。违背 FR-07.4/07.5、05§3/05§8。**P0，中**。
  - **导入非事务**：apply() 依次写 manifest→script→auth（ProviderImporter.apply:221-255），中途失败不清自身新产物（留下半成品插件目录）；无"全成功才登记"。违背 FR-07.6。**中**。
  - 导入循环同步跑在 MainActor（importSelected 为同步 for 循环），导入中 UI 冻结、无取消。违背 FR-07.1 可取消/07.8 取消语义。**小-中**。
  - 扫描超时后工作 task 未真正取消（group.cancelAll 不杀 sqlite 子进程，任务孤儿继续跑）（ImportCenterSheet.swift:131-157）。违背 FR-07.1 可取消。**小**。
  - 跨源疑似同账号无提示（FR-07.5 后半）。**小**。

### FR-08 管理窗、菜单栏、悬浮窗、HUD 一致

- 现状：设置中心三 tab 真实内容+草稿；菜单栏/悬浮/HUD 同读 states/缓存文件；悬浮窗 nonactivating+双击对称+右键菜单（FloatingView.swift:35-67）；设置窗单例+位置记忆+关窗 guard（StatusItemController.swift:140-177）。
- 符合：FR-08.3/08.4（tab 真切换、保存栏固定、错误可达可跳 tab）、FR-08.7 大部（开关对称、右键含主操作/开关/管理/退出、文案随状态）、FR-10.3（单例/位置/X/Esc）。
- 差距：
  - **"立刻刷新"= 对全部账号发模型调用**：菜单栏右键、MenuBar 面板、悬浮窗右键的"立刻刷新/立即刷新"都走 triggerAndRefreshAll（DataEngine.swift:353-375——先对每家 POST chat 再查余额），**一键隐式消费全部账号额度且无任何确认**。违背 FR-04.1/04.2、FR-08.5"快览默认查询不调用模型"。**P0，小**（改行为：快览刷新只查余额；触发调用仅保留在账号详情显式动作）。
  - HUD 投影（envs.json/statusline.mjs）与缓存 schema 均无版本化（HUDSync.swift 全文、Models.swift），05§9 要求 canonical/projection 分版本。**中**。
  - 正文最小字号：Typo.small=11pt 多处（Theme.swift）< 规范最小 12。**小**。
  - 主窗 minSize 760×480（StatusItemController.swift:161）< 建议 820×560。**小**。

### FR-09 错误恢复、日志与诊断

- 现状：错误码→人话映射（DataEngine.reason:344-350）；旧值与错误同屏（QuotaTabView isOldValue:81-84）；stderr 尾 4KB 落 `.{slug}-usage-stderr.log`（ProviderRunner.dumpStderr:94-100）；toast 全按钮反馈。
- 符合：FR-09.1 部分（查询/快照两维分列）、FR-09.6 部分（按钮反馈不静默）。
- 差距：
  - **四态未区分**：无 未配置/未接入/不支持/待核实 的体系，现有文案混用"未适配/未提供额度查询接口/尚未配置调用端点"（QuotaTabView:29、ConfigTabView/TriggerTabView 各处）。违背 FR-09.4。**中**。
  - **无 opId/attempt 起止**：诊断无法关联"哪次操作"；无 lastAttemptAt/lastSuccessAt 分离（见 FR-03）。违背 FR-09.2/09.5。**中**（随 op 体系）。
  - stderr 日志无脱敏保证（脚本 stderr 原样落盘，若脚本打印 token 即泄露）；日志无 accountId/opId 结构。违背 FR-09.5、NFR-03。**小**。

### FR-10 持久化、升级与窗口行为

- 现状：所有 JSON 写入 `.atomic`（ProviderConfigStore.write:130-131、DataEngine.writeCache:433-435、HUDSync）；设置窗单例+autosave 位置+关窗走 leaveGuard；跨重启恢复选中账号与 tab（SettingsPersist:142-155，有测试）。
- 符合：FR-10.3 全项、FR-10.2 大部（取消/切账号/新增/关窗同一 guard，SettingsModel.leaveGuard:697-706 + SettingsWindowManager.windowShouldClose:173-176）。
- 差距：
  - **全部存储无 schemaVersion**：manifest/auth/cache/envs 均裸 JSON，无迁移框架；首启 migrateAccounts 每次启动覆盖实例 manifest 能力字段（DataEngine.swift:160-183，仅保 displayName——用户对 manifest 的其他手改会被抹）。违背 FR-10.4/10.5、05§9。**中**。
  - 凭证文件未设 0600（UI 却宣称 600）。违背 NFR-03。**小**。
  - 侧栏"导入…"入口未走草稿 guard（SettingsCenterView.swift:153 直接 importOpen=true，而 selectAccount/openTemplates 均有 guard）。违背 FR-10.2 同一保护规则。**小**。
  - package.sh：版本硬编码 0.1.0、ad-hoc 签名、无"安装包与验收版本一致"核对步骤（scripts/package.sh 全文）。违背 FR-10.5。**小**。

### NFR 横切

- NFR-01：旧值/不造 0 做到；窗口/单位/金额语义缺（随 FR-03）。NFR-02：超时有（脚本 20s）；并发/取消/去重/唤醒/DST 策略缺（随 FR-05/06）。NFR-03：原子写有；0600/日志脱敏缺。NFR-04：交互基线大体达；导入入口 guard/最小字号缺。NFR-05：75 测试+离屏渲染钩子存在，但离屏渲染按 06 明确不能代替原生点击验收——当前无任何原生交互证据（全部"未验"）。

## 3. 重点线索逐项结论（对应任务书 8 条）

1. **slug 主键 vs 05§3**：slug 兼任文件名/身份/缓存键，无 UUID、无 origin、无四级 revision。迟到回包与删除竞态仅靠"slug 查不到"兜底，换 key 竞态完全无防护。
2. **UsageCache**：generatedAt 单时间戳被失败推进（DataEngine.swift:414），error/stale 是仅有维度；无 snapshotCapturedAt/lastSuccessAt 持久/身份绑定。**失败确实"推进了成功时间"**（generatedAt 即 statusline/HUD 判断新鲜的唯一依据）。
3. **查询执行**：无 opId/合并键/并发上限/429 退避；due=isFresh 推导；保存还会主动触发一次查询。
4. **RefreshTrigger**：无消费确认的"立刻刷新"全员 POST；无超时；结果不确定不表达；无并发位；200=成功。
5. **checkSchedules**：无持久 started，内存 HH:MM 键跨天误杀（单时刻账号只触发一次）、跨重启可重复；无 DST/本地日期概念。
6. **ProviderImporter**：无事务、失败不清理；查重按显示名（方向反了）；无 origin 标识。
7. **SettingsCenter UI**：草稿 guard 统一（除导入入口）；两开关独立达标；错误四态未区分；"保存并发送测试调用"非规范要求的草稿测试。
8. **存储**：原子写全覆盖；无版本化/迁移；migrateAccounts 启动即覆盖；凭证文件无 0600。

## 4. 修复路线

### P0 数据正确性（先做，5 条）

| # | 项 | 违背 | 改动文件 | 规模 |
| --- | --- | --- | --- | --- |
| P0-1 | 快照时间语义：UsageCache 拆 lastAttemptAt/snapshotCapturedAt/lastSuccessAt，失败不再推进任何时间；isFresh 改基于 lastSuccessAt | FR-03.8、FR-09.2、05§4 | Models.swift、DataEngine.swift、statusline.mjs（读端） | 中 |
| P0-2 | 回包版本核对：引入 accountId+credentialRevision（先做 slug 级 revision 亦可），fetch/forceRefresh 提交前核对；删除清 cache+envs | FR-05.3、FR-01.6、05§3 | DataEngine.swift、SettingsModel.delete | 中 |
| P0-3 | 调度持久去重：started 键 = slug+本地日期+HH:MM 落盘（UserDefaults 或 JSON），修跨天误杀与跨重启重复；顺带 skipped 记录 | FR-06.3/06.4/06.5、05§7 | DataEngine.checkSchedules | 小-中 |
| P0-4 | 导入去重改 origin：候选带 source+stableRecordId，账号登记 origin，同名不判重；同源再导默认 skip | FR-07.4/07.5、05§8 | ProviderImporter、ImportCenterModel.stateOf、账号元数据落盘 | 中 |
| P0-5 | 摘除隐式消费：菜单栏/悬浮/HUD 面板"立刻刷新"改为只查余额（不 POST chat）；trigger 型动作只保留账号详情显式按钮 | FR-04.1/04.2、FR-08.5 | DataEngine.triggerAndRefreshAll、StatusItemController、MenuBarView、FloatingView | 小 |

### P1 行为正确性（11 条）

| # | 项 | 违背 | 改动文件 | 规模 |
| --- | --- | --- | --- | --- |
| P1-1 | 保存不发请求：删 save() 内 forceRefresh；due 改"生效时刻+新间隔" | FR-05.2 | SettingsModel.save、DataEngine | 小 |
| P1-2 | 查询 op 体系：opId+合并键+全局 3/每账号 1 执行位+latest-only 接替 | FR-05.3/05.4 | DataEngine（新建 QueryExecutor） | 中 |
| P1-3 | 429/401 退避：脚本回传 HTTP 语义，引擎按 Retry-After/max(interval,60s) 暂停对应账号 | FR-05.5 | mjs 脚本+DataEngine | 中 |
| P1-4 | 模型并发位：每账号 1/全局 2，计划触发 busy→skipped；唤醒补查每账号一次 | FR-06.6、FR-05.6 | DataEngine | 中 |
| P1-5 | 调用结果不确定：URLRequest timeoutInterval=20；网络异常标"结果不确定，可能已消费"；业务校验成功 | FR-04.4/04.5 | RefreshTrigger.send、SettingsModel.testCall | 小 |
| P1-6 | 启用确认+草稿测试：autoTrigger 开启时消费确认弹窗；"用当前草稿发送测试调用"（不保存） | FR-06.1、FR-04.7 | SettingsModel、DraftFormView | 中 |
| P1-7 | 导入事务化：apply 失败清自身产物；导入循环移后台+可取消；扫描超时真取消 | FR-07.6/07.8/07.1 | ProviderImporter.apply、ImportCenterModel | 中 |
| P1-8 | 错误四态：未配置/未接入/不支持/待核实 文案与判定分离 | FR-09.4 | QuotaTab/ConfigTab/TriggerTab | 中 |
| P1-9 | 空 key=保持原值+替换/清除独立意图与确认 | FR-02.2/02.3 | SettingsValidation、DraftFormView、SettingsModel.update | 中 |
| P1-10 | 合法不完整可保存并标未配置、对应任务 OFF | FR-01.5 | SettingsValidation、SettingsModel.save | 中 |
| P1-11 | 动态窗口列表：缓存契约窗口数组化（used/remaining/percent/单位/limit/period/resetsAt），UI 按实际渲染 | FR-03.5/03.6 | Models、mjs 脚本、QuotaTabView | 大 |

### P2 UI 完整性与交付（7 条）

| # | 项 | 违背 | 改动文件 | 规模 |
| --- | --- | --- | --- | --- |
| P2-1 | 导入入口走草稿 guard | FR-10.2 | SettingsCenterView 侧栏 | 小 |
| P2-2 | 凭证文件 chmod 0600（或迁 Keychain，留评估） | NFR-03 | PluginGenerator、ProviderConfigStore | 小 |
| P2-3 | 存储版本化：auth/cache/envs 加 schemaVersion+迁移入口；migrateAccounts 不再无脑覆盖 | FR-10.4 | 各 Store | 中 |
| P2-4 | stderr 日志脱敏（token/Authorization 行过滤）+accountId 关联 | FR-09.5、NFR-03 | ProviderRunner.dumpStderr | 小 |
| P2-5 | 正文字号≥12、主窗 minSize 调 820×560 | FR-08.6 | Theme、SettingsWindowManager | 小 |
| P2-6 | 默认 prompt/max_tokens 对齐"只回复OK"+16（provider 可声明覆盖） | FR-04.3 | RefreshTrigger、manifest | 小 |
| P2-7 | package.sh 版本注入+安装后版本核对输出 | FR-10.5 | scripts/package.sh | 小 |

### 顺序建议

P0 全部 → P1-1/5/6/9/10（小-中、直接对齐验收链）→ P1-2/3/4/7/8/11 → P2。P1-11（窗口契约）改动面最大（脚本+mjs+UI），可单独成批。原生交互证据（06 的 36 条链）在代码修复后按 U-01~U-36 走真机验收，当前全部"未验"。

## 5. 测试与证据现状

- 既有 75 测试覆盖：配置读写、导入解析、生成器、引擎刷新、HUD 合并、注册表、runner 超时、跨重启恢复——为上述 P0/P1 修复提供回归底座。
- 缺口测试：调度去重跨天/跨重启、迟到回包丢弃、导入 origin 去重、429 退避、结果不确定——修复时须按 05§11 事件场景补（可控时钟、隔离 HOME）。
