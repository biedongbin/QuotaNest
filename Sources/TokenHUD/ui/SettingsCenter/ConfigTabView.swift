import SwiftUI

struct ProviderCapabilityPresentation {
    let manifest: ProviderManifest?
    let generic: Bool

    var allowsAuth: Bool { manifest?.credentialSource != nil }
    var allowsAPIKey: Bool {
        manifest?.refreshUrl?.isEmpty == false || manifest?.quotaAuthModes?.contains("apikey") == true
            || (generic && !allowsAuth)
    }
    func authenticationIssue(for mode: String) -> String? {
        switch mode {
        case "auth": return allowsAuth ? nil : L10n.tr("此类型未声明授权文件来源，请选择可用的认证方式。")
        case "apikey": return allowsAPIKey ? nil : L10n.tr("此类型未接入 API Key 认证，请改用授权文件。已保存的认证方式尚未更改。")
        default: return L10n.tr("已保存的认证方式（%@）不受支持，请选择可用的认证方式。", String(describing: mode))
        }
    }
    func canCall(using mode: String) -> Bool {
        guard authenticationIssue(for: mode) == nil else { return false }
        if mode == "auth" {
            return manifest?.authCallUrl?.isEmpty == false
                && ["openai", "anthropic", "responses"].contains(manifest?.authCallProtocol ?? "")
        }
        return generic || manifest?.refreshUrl?.isEmpty == false
    }
    var authenticationSummary: String {
        let modes = [(allowsAPIKey, "API Key"), (allowsAuth, L10n.tr("授权文件"))].filter { $0.0 }.map { $0.1 }
        return modes.isEmpty ? L10n.tr("认证方式未接入") : modes.joined(separator: " / ")
    }
    var capabilitySummary: String {
        if canCall(using: "apikey") || canCall(using: "auth") {
            return manifest?.supportsQuota == true ? L10n.tr("用量查询 · 模型调用") : (generic ? L10n.tr("模型调用 · 用量查询可选") : L10n.tr("模型调用 · 用量查询未接入"))
        }
        return manifest?.supportsQuota == true ? L10n.tr("仅用量查询，模型调用与调度未接入") : L10n.tr("用量查询、模型调用与调度未接入")
    }
    static func matches(_ choice: TemplateChoice, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [choice.label, choice.id, choice.manifest?.name ?? ""]
            .contains { $0.range(of: query, options: .caseInsensitive) != nil }
    }
}

struct ConfigTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow
    @State private var renameOpen = false
    @State private var localName = ""
    @State private var temporaryModel = ""
    private var config: ProviderConfig { model.readConfig(row.plugin) }
    private var capability: ProviderCapabilityPresentation {
        ProviderCapabilityPresentation(manifest: row.plugin.manifest, generic: !row.builtin)
    }
    private var canCall: Bool { capability.canCall(using: config.authMode) }
    private var readOnly: Bool { row.plugin.manifest.isSourceConfigurationReadOnly }
    private var resolvedCall: ProviderConfig? { try? ProviderAuthentication.resolveCall(config) }
    private var testReady: Bool { model.callConfigured(row, modelOverride: readOnly ? temporaryModel : nil) }
    private var quotaAddress: String {
        do {
            let resolved = try ProviderAuthentication.resolveQuota(config)
            return resolved.queryUrl.isEmpty ? L10n.tr("供应商脚本") : (readOnly ? SettingsModel.safeSourceLocation(resolved.queryUrl) : resolved.queryUrl)
        } catch {
            return L10n.tr("基础认证解析失败，查询地址暂不可用")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.tr("连接配置")).font(.headline)
                Spacer()
                Button(L10n.tr("修改显示名"), systemImage: "pencil") {
                    localName = row.name
                    renameOpen = true
                }.barButton().accessibilityIdentifier("account.rename")
                AccountActionButton(title: L10n.tr("编辑连接"), identifier: "account.edit-connection", enabled: !readOnly) {
                    model.startEdit()
                }.fixedSize().frame(height: 28)
            }
            if readOnly { sourceDetails }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                apiConnection
                quotaConnection
            }
            HStack {
                Button(L10n.tr("复制账号…"), systemImage: "plus.square.on.square") { model.duplicateAccount(row.id) }
                    .disabled(readOnly)
                Spacer()
                Button(L10n.tr("删除账号…"), role: .destructive) { model.delete(row.id) }
            }
        }
        .onAppear { temporaryModel = resolvedCall?.testModel ?? "" }
        .onChange(of: row.id) { _, _ in temporaryModel = resolvedCall?.testModel ?? ""; renameOpen = false }
        .alert(L10n.tr("修改本地显示名"), isPresented: $renameOpen) {
            TextField(L10n.tr("账号名称"), text: $localName)
            Button(L10n.tr("取消"), role: .cancel) {}
            Button(L10n.tr("保存")) { model.renameDisplayName(row.id, name: localName) }
        } message: { Text(L10n.tr("仅修改 QuotaNest 中的显示名，不修改来源账号。")) }
    }
    private var sourceDetails: some View {
        GroupBox(L10n.tr("来源配置 · 只读")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(SettingsModel.sourceReadOnlyMessage).font(.callout)
                if let source = row.plugin.manifest.sourceReference {
                    KeyValueRow(L10n.tr("来源工具")) { Text(source.source) }
                    KeyValueRow(L10n.tr("记录 ID"), mono: true) { Text(source.recordId) }
                    KeyValueRow("Provider ID", mono: true) { Text(source.providerId ?? L10n.tr("未记录")) }
                    if let original = source.originalRecordId, original != source.recordId {
                        KeyValueRow(L10n.tr("原始记录 ID"), mono: true) { Text(original) }
                    }
                    if let original = source.originalProviderId, original != source.providerId {
                        KeyValueRow(L10n.tr("原始 Provider ID"), mono: true) { Text(original) }
                    }
                    if let issue = model.engine.sourceSyncIssues[row.id] {
                        Label(L10n.tr("来源同步待处理：") + issue, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Palette.warn)
                    }
                    KeyValueRow(L10n.tr("来源位置"), mono: true) { Text(SettingsModel.safeSourceLocation(source.path)) }
                } else {
                    KeyValueRow(L10n.tr("旧来源标识"), mono: true) { Text(row.plugin.manifest.origin ?? L10n.tr("未记录")) }
                    Text(L10n.tr("旧导入账号已锁定；来源引用待迁移，请到原工具修改。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var apiConnection: some View {
        GroupBox(L10n.tr("① 基础接入")) {
                VStack(alignment: .leading, spacing: 8) {
                    if canCall {
                        KeyValueRow(L10n.tr("服务地址"), mono: true) {
                            let address = model.baseAddressDescription(config)
                            Text(readOnly ? SettingsModel.safeSourceLocation(address) : address)
                        }
                        KeyValueRow(L10n.tr("协议")) { Text(model.baseProtocolDescription(config)) }
                    } else {
                        Label(L10n.tr("当前认证的模型调用与调度未接入"), systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let issue = capability.authenticationIssue(for: config.authMode) {
                        Text(issue).font(.callout).foregroundStyle(Palette.warn)
                    }
                    KeyValueRow(L10n.tr("认证方式")) { Text(config.authMode == "auth" ? L10n.tr("Auth · 授权文件") : (config.authMode == "apikey" ? "API Key" : config.authMode)) }
                    if readOnly {
                        KeyValueRow(L10n.tr("基础凭证")) {
                            Text(row.plugin.manifest.sourceReference == nil ? L10n.tr("旧导入凭证已锁定，等待来源引用迁移") : L10n.tr("运行时只读引用来源认证，不复制凭证"))
                        }
                        if let issue = model.authenticationIssue(config) {
                            Text(issue).font(.callout).foregroundStyle(Palette.danger).textSelection(.enabled)
                        }
                    } else if config.authMode == "auth" {
                        KeyValueRow(L10n.tr("有效来源")) { Text(model.authSourceDescription(config)) }
                        if canCall, let issue = model.authenticationIssue(config) {
                            Text(issue).font(.callout).foregroundStyle(Palette.danger).textSelection(.enabled)
                        }
                    } else {
                        KeyValueRow(L10n.tr("基础凭证")) { Text(maskKey(config.refreshKey)) }
                    }
                    if canCall {
                        KeyValueRow(L10n.tr("模型"), mono: true) {
                            let modelName = row.plugin.manifest.sourceReference == nil ? config.testModel : resolvedCall?.testModel ?? ""
                            Text(modelName.isEmpty ? L10n.tr("未指定") : modelName)
                        }
                    }
                    if row.builtin && canCall { Label(L10n.tr("供应商类型固定服务地址与协议"), systemImage: "lock").font(.callout).foregroundStyle(.secondary) }
                    if readOnly && canCall {
                        TextField(L10n.tr("临时测试模型"), text: $temporaryModel)
                            .fieldBox().accessibilityIdentifier("account.source-test-model")
                        ModelCatalogControls(model: model, savedAccount: row, modelSelection: $temporaryModel)
                        Text(L10n.tr("模型只用于本次测试，不修改来源配置或调用计划。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label(!canCall ? L10n.tr("模型测试与调度未接入") : (testReady ? L10n.tr("调用配置完整") : L10n.tr("调用尚未配置完整")),
                              systemImage: testReady ? "checkmark.circle" : "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.callRunning.contains(row.id) ? L10n.tr("测试中…") : L10n.tr("测试 API 调用")) {
                            model.testCall(row.id, modelOverride: readOnly ? temporaryModel : nil)
                        }
                            .disabled(!canCall || !testReady || model.callRunning.contains(row.id))
                            .help(!canCall ? L10n.tr("此类型未接入模型调用，不是来源只读限制。") : L10n.tr("选择模型后发送一次已确认的测试请求。"))
                    }
                    Text(canCall ? (readOnly ? L10n.tr("使用来源认证和临时模型发送一次请求，会消耗账号额度。") : L10n.tr("使用已保存配置发送一次请求，会消耗账号额度。")) : L10n.tr("可使用已接入的用量查询；此类型当前不提供模型测试或调用计划。")).font(.caption).foregroundStyle(.secondary)
                    if let result = model.callTestResult(for: row.id) { CallTestResultView(result: result) }
                }
            }
    }
    private var quotaConnection: some View {
        GroupBox(L10n.tr("② 用量查询 · 可选")) {
                VStack(alignment: .leading, spacing: 8) {
                    if row.canQuery && config.quotaMode != "none" {
                        KeyValueRow(L10n.tr("查询地址"), mono: true) { Text(quotaAddress) }
                        KeyValueRow(L10n.tr("查询认证")) { Text(L10n.tr("跟随基础接入")) }
                        Text(model.quotaConfigured(row) ? L10n.tr("用量查询配置已就绪。") : (model.quotaAuthenticationIssue(config) ?? L10n.tr("请检查基础接入的查询地址配置。")))
                            .font(.callout).foregroundStyle(.secondary)
                        Button(L10n.tr("查看额度"), systemImage: "chart.bar") { model.tab = .quota }
                    } else {
                        Label(L10n.tr("未启用额度查询"), systemImage: "minus.circle").foregroundStyle(.secondary)
                        Text(readOnly ? L10n.tr("用量查询由来源配置提供，请到来源工具修改。") : (canCall ? L10n.tr("API 调用和调用计划可独立使用。需要时编辑连接，选择额度查询方式。") : L10n.tr("请编辑连接，检查基础认证与供应商用量查询能力。")))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
    }
}

struct TriggerTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow
    private var config: ProviderConfig { model.readConfig(row.plugin) }
    private var canCall: Bool {
        ProviderCapabilityPresentation(manifest: row.plugin.manifest, generic: !row.builtin).canCall(using: config.authMode)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.tr("调用计划")).font(.headline)
                Spacer()
                Button(L10n.tr("编辑计划"), systemImage: "pencil") { model.startEdit() }
                    .disabled(row.plugin.manifest.isSourceConfigurationReadOnly)
            }
            if row.plugin.manifest.isSourceConfigurationReadOnly {
                Label(SettingsModel.sourceReadOnlyMessage, systemImage: "lock").font(.callout)
            }
            GroupBox(L10n.tr("③ API 调度 · 启动 5h 使用窗口")) {
                VStack(alignment: .leading, spacing: 12) {
                    Label(planState, systemImage: "calendar.badge.clock")
                    KeyValueRow(L10n.tr("调用模型"), mono: true) {
                        let modelName = row.plugin.manifest.sourceReference == nil ? config.testModel
                            : (try? ProviderAuthentication.resolveCall(config).testModel) ?? ""
                        Text(modelName.isEmpty ? L10n.tr("未指定") : modelName)
                    }
                    if !config.scheduleTimes.isEmpty {
                        Text(config.scheduleTimes.joined(separator: "、")).monospacedDigit().textSelection(.enabled)
                    }
                    Text(canCall ? L10n.tr("在设置时间尝试主动开启动态 5h 使用窗口，不保证供应商必然开窗。使用本机时区 %@，到点发送一次调用并消耗额度。", String(describing: TimeZone.current.identifier)) : L10n.tr("当前认证的模型调用与调度未接入；用量查询可独立使用。"))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(L10n.tr("使用基础接入认证及目标套餐可调用模型。仅执行用户设置的时间，不推断或自动重置窗口。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if row.canQuery {
                GroupBox(L10n.tr("后台额度查询")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper(L10n.tr("查询间隔：%@ 分钟", String(describing: interval)), value: Binding(get: { interval }, set: {
                            model.engine.setIntervalMinutes(row.id, minutes: $0)
                        }), in: 1...1440)
                            .disabled(!row.enabled || !model.quotaConfigured(row))
                        if model.engine.hasIntervalOverride(row.id) {
                            Button(L10n.tr("恢复供应商默认间隔")) { model.engine.clearIntervalOverride(row.id) }
                        }
                        Text(L10n.tr("间隔立即生效。账号停用时后台查询暂停。")).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var interval: Int { model.engine.effectiveIntervalMinutes(row.id, manifest: row.plugin.manifest) }
    private var planState: String {
        let capability = ProviderCapabilityPresentation(manifest: row.plugin.manifest, generic: !row.builtin)
        if !capability.canCall(using: config.authMode) { return L10n.tr("当前认证的模型调用与调度未接入") }
        if !model.callConfigured(row) { return L10n.tr("请先配置 API 调用") }
        if config.scheduleTimes.isEmpty { return L10n.tr("未设置调用时间") }
        if model.engine.triggerDisabledSlugs.contains(row.id) { return L10n.tr("计划已关闭") }
        return row.enabled ? L10n.tr("计划已启用") : L10n.tr("账号已停用，计划暂停")
    }
}

struct UnsupportedBox: View {
    let title: String
    let detail: String
    var body: some View { ResultBox(kind: .neutral, title: title, detail: detail) }
}

struct TemplateCatalogView: View {
    @ObservedObject var model: SettingsModel
    @State private var search = ""
    private var choices: [TemplateChoice] {
        model.choices.filter { ProviderCapabilityPresentation.matches($0, search: search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.tr("选择供应商类型")).font(.title2.weight(.semibold))
                Spacer()
                Button {
                    FeedbackWindowManager.shared.show(context: .init(area: .providerCatalog, stage: .catalog))
                } label: { Label(L10n.tr("反馈问题／申请支持"), systemImage: "bubble.left") }
                .barButton().accessibilityIdentifier("feedback.provider-entry")
            }
            Text(L10n.tr("类型可以重复使用，每个账号单独保存凭证、计划与显示选择。"))
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L10n.tr("搜索供应商名称或 ID"), text: $search)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(L10n.tr("搜索供应商类型"))
                    .accessibilityIdentifier("template.search")
                if !search.isEmpty {
                    Button(L10n.tr("清除搜索")) { search = "" }
                }
            }
            if choices.isEmpty {
                Text(L10n.tr("没有匹配的供应商类型，请尝试其他名称或 ID。"))
                    .foregroundStyle(.secondary).accessibilityIdentifier("template.empty-results")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                ForEach(choices) { choice in
                    Button { model.pickTemplate(choice) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                ProviderLogo(manifest: choice.manifest, slug: choice.id, size: 18)
                                Text(choice.label).font(.headline)
                            }
                            Text(ProviderCapabilityPresentation(manifest: choice.manifest, generic: choice.manifest == nil).authenticationSummary)
                                .font(.callout)
                            Text(ProviderCapabilityPresentation(manifest: choice.manifest, generic: choice.manifest == nil).capabilitySummary)
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(12).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                    }.buttonStyle(.bordered)
                        .accessibilityIdentifier("template.\(choice.id)")
                        .contextMenu { Button(L10n.tr("添加此类型账号")) { model.pickTemplate(choice) } }
                }
            }
        }
    }
}
