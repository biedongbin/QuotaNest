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
        case "auth": return allowsAuth ? nil : "此类型未声明授权文件来源，请选择可用的认证方式。"
        case "apikey": return allowsAPIKey ? nil : "此类型未接入 API Key 认证，请改用授权文件。已保存的认证方式尚未更改。"
        default: return "已保存的认证方式（\(mode)）不受支持，请选择可用的认证方式。"
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
        let modes = [(allowsAPIKey, "API Key"), (allowsAuth, "授权文件")].filter { $0.0 }.map { $0.1 }
        return modes.isEmpty ? "认证方式未接入" : modes.joined(separator: " / ")
    }
    var capabilitySummary: String {
        if canCall(using: "apikey") || canCall(using: "auth") {
            return manifest?.supportsQuota == true ? "用量查询 · 模型调用" : (generic ? "模型调用 · 用量查询可选" : "模型调用 · 用量查询未接入")
        }
        return manifest?.supportsQuota == true ? "仅用量查询，模型调用与调度未接入" : "用量查询、模型调用与调度未接入"
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
    private var config: ProviderConfig { model.readConfig(row.plugin) }
    private var capability: ProviderCapabilityPresentation {
        ProviderCapabilityPresentation(manifest: row.plugin.manifest, generic: !row.builtin)
    }
    private var canCall: Bool { capability.canCall(using: config.authMode) }
    private var readOnly: Bool { row.plugin.manifest.isSourceConfigurationReadOnly }
    private var resolvedCall: ProviderConfig? { try? ProviderAuthentication.resolveCall(config) }
    private var quotaAddress: String {
        do {
            let resolved = try ProviderAuthentication.resolveQuota(config)
            return resolved.queryUrl.isEmpty ? "供应商脚本" : (readOnly ? SettingsModel.safeSourceLocation(resolved.queryUrl) : resolved.queryUrl)
        } catch {
            return "基础认证解析失败，查询地址暂不可用"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("连接配置").font(.headline)
                Spacer()
                AccountActionButton(title: "编辑连接", identifier: "account.edit-connection", enabled: !readOnly) {
                    model.startEdit()
                }.fixedSize().frame(height: 28)
            }
            if readOnly { sourceDetails }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                apiConnection
                quotaConnection
            }
            HStack {
                Button("复制账号…", systemImage: "plus.square.on.square") { model.duplicateAccount(row.id) }
                    .disabled(readOnly)
                Spacer()
                Button("删除账号…", role: .destructive) { model.delete(row.id) }
            }
        }
    }
    private var sourceDetails: some View {
        GroupBox("来源配置 · 只读") {
            VStack(alignment: .leading, spacing: 8) {
                Text(SettingsModel.sourceReadOnlyMessage).font(.callout)
                if let source = row.plugin.manifest.sourceReference {
                    KeyValueRow("来源工具") { Text(source.source) }
                    KeyValueRow("记录 ID", mono: true) { Text(source.recordId) }
                    KeyValueRow("Provider ID", mono: true) { Text(source.providerId ?? "未记录") }
                    KeyValueRow("来源位置", mono: true) { Text(SettingsModel.safeSourceLocation(source.path)) }
                } else {
                    KeyValueRow("旧来源标识", mono: true) { Text(row.plugin.manifest.origin ?? "未记录") }
                    Text("旧导入账号已锁定；来源引用待迁移，请到原工具修改。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var apiConnection: some View {
        GroupBox("① 基础接入") {
                VStack(alignment: .leading, spacing: 8) {
                    if canCall {
                        KeyValueRow("服务地址", mono: true) {
                            let address = model.baseAddressDescription(config)
                            Text(readOnly ? SettingsModel.safeSourceLocation(address) : address)
                        }
                        KeyValueRow("协议") { Text(model.baseProtocolDescription(config)) }
                    } else {
                        Label("当前认证的模型调用与调度未接入", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let issue = capability.authenticationIssue(for: config.authMode) {
                        Text(issue).font(.callout).foregroundStyle(Palette.warn)
                    }
                    KeyValueRow("认证方式") { Text(config.authMode == "auth" ? "Auth · 授权文件" : (config.authMode == "apikey" ? "API Key" : config.authMode)) }
                    if readOnly {
                        KeyValueRow("基础凭证") {
                            Text(row.plugin.manifest.sourceReference == nil ? "旧导入凭证已锁定，等待来源引用迁移" : "运行时只读引用来源认证，不复制凭证")
                        }
                        if let issue = model.authenticationIssue(config) {
                            Text(issue).font(.callout).foregroundStyle(Palette.danger).textSelection(.enabled)
                        }
                    } else if config.authMode == "auth" {
                        KeyValueRow("有效来源") { Text(model.authSourceDescription(config)) }
                        if canCall, let issue = model.authenticationIssue(config) {
                            Text(issue).font(.callout).foregroundStyle(Palette.danger).textSelection(.enabled)
                        }
                    } else {
                        KeyValueRow("基础凭证") { Text(maskKey(config.refreshKey)) }
                    }
                    if canCall {
                        KeyValueRow("模型", mono: true) {
                            let modelName = row.plugin.manifest.sourceReference == nil ? config.testModel : resolvedCall?.testModel ?? ""
                            Text(modelName.isEmpty ? "未指定" : modelName)
                        }
                    }
                    if row.builtin && canCall { Label("供应商类型固定服务地址与协议", systemImage: "lock").font(.callout).foregroundStyle(.secondary) }
                    HStack {
                        Label(!canCall ? "模型测试与调度未接入" : (model.callConfigured(row) ? "调用配置完整" : "调用尚未配置完整"),
                              systemImage: model.callConfigured(row) ? "checkmark.circle" : "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.callRunning.contains(row.id) ? "测试中…" : "测试 API 调用") { model.testCall(row.id) }
                            .disabled(!canCall || !model.callConfigured(row) || model.callRunning.contains(row.id))
                    }
                    Text(canCall ? "使用已保存配置发送一次请求，会消耗账号额度。" : "可使用已接入的用量查询；此类型当前不提供模型测试或调用计划。").font(.caption).foregroundStyle(.secondary)
                    if let result = model.callTestResult(for: row.id) { CallTestResultView(result: result) }
                }
            }
    }
    private var quotaConnection: some View {
        GroupBox("② 用量查询 · 可选") {
                VStack(alignment: .leading, spacing: 8) {
                    if row.canQuery && config.quotaMode != "none" {
                        KeyValueRow("查询地址", mono: true) { Text(quotaAddress) }
                        KeyValueRow("查询认证") { Text("跟随基础接入") }
                        Text(model.quotaConfigured(row) ? "用量查询配置已就绪。" : (model.quotaAuthenticationIssue(config) ?? "请检查基础接入的查询地址配置。"))
                            .font(.callout).foregroundStyle(.secondary)
                        Button("查看额度", systemImage: "chart.bar") { model.tab = .quota }
                    } else {
                        Label("未启用额度查询", systemImage: "minus.circle").foregroundStyle(.secondary)
                        Text(readOnly ? "用量查询由来源配置提供，请到来源工具修改。" : (canCall ? "API 调用和调用计划可独立使用。需要时编辑连接，选择额度查询方式。" : "请编辑连接，检查基础认证与供应商用量查询能力。"))
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
                Text("调用计划").font(.headline)
                Spacer()
                Button("编辑计划", systemImage: "pencil") { model.startEdit() }
                    .disabled(row.plugin.manifest.isSourceConfigurationReadOnly)
            }
            if row.plugin.manifest.isSourceConfigurationReadOnly {
                Label(SettingsModel.sourceReadOnlyMessage, systemImage: "lock").font(.callout)
            }
            GroupBox("③ API 调度 · 启动 5h 使用窗口") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(planState, systemImage: "calendar.badge.clock")
                    KeyValueRow("调用模型", mono: true) {
                        let modelName = row.plugin.manifest.sourceReference == nil ? config.testModel
                            : (try? ProviderAuthentication.resolveCall(config).testModel) ?? ""
                        Text(modelName.isEmpty ? "未指定" : modelName)
                    }
                    if !config.scheduleTimes.isEmpty {
                        Text(config.scheduleTimes.joined(separator: "、")).monospacedDigit().textSelection(.enabled)
                    }
                    Text(canCall ? "在设置时间尝试主动开启动态 5h 使用窗口，不保证供应商必然开窗。使用本机时区 \(TimeZone.current.identifier)，到点发送一次调用并消耗额度。" : "当前认证的模型调用与调度未接入；用量查询可独立使用。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("使用基础接入认证及目标套餐可调用模型。仅执行用户设置的时间，不推断或自动重置窗口。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if row.canQuery {
                GroupBox("后台额度查询") {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper("查询间隔：\(interval) 分钟", value: Binding(get: { interval }, set: {
                            model.engine.setIntervalMinutes(row.id, minutes: $0)
                        }), in: 1...1440)
                            .disabled(!row.enabled || !model.quotaConfigured(row))
                        if model.engine.hasIntervalOverride(row.id) {
                            Button("恢复供应商默认间隔") { model.engine.clearIntervalOverride(row.id) }
                        }
                        Text("间隔立即生效。账号停用时后台查询暂停。").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var interval: Int { model.engine.effectiveIntervalMinutes(row.id, manifest: row.plugin.manifest) }
    private var planState: String {
        let capability = ProviderCapabilityPresentation(manifest: row.plugin.manifest, generic: !row.builtin)
        if !capability.canCall(using: config.authMode) { return "当前认证的模型调用与调度未接入" }
        if !model.callConfigured(row) { return "请先配置 API 调用" }
        if config.scheduleTimes.isEmpty { return "未设置调用时间" }
        if model.engine.triggerDisabledSlugs.contains(row.id) { return "计划已关闭" }
        return row.enabled ? "计划已启用" : "账号已停用，计划暂停"
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
            Text("选择供应商类型").font(.title2.weight(.semibold))
            Text("类型可以重复使用，每个账号单独保存凭证、计划与显示选择。")
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜索供应商名称或 ID", text: $search)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("搜索供应商类型")
                    .accessibilityIdentifier("template.search")
                if !search.isEmpty {
                    Button("清除搜索") { search = "" }
                }
            }
            if choices.isEmpty {
                Text("没有匹配的供应商类型，请尝试其他名称或 ID。")
                    .foregroundStyle(.secondary).accessibilityIdentifier("template.empty-results")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                ForEach(choices) { choice in
                    Button { model.pickTemplate(choice) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(choice.label, systemImage: choice.manifest == nil ? "network" : "shippingbox")
                                .font(.headline)
                            Text(ProviderCapabilityPresentation(manifest: choice.manifest, generic: choice.manifest == nil).authenticationSummary)
                                .font(.callout)
                            Text(ProviderCapabilityPresentation(manifest: choice.manifest, generic: choice.manifest == nil).capabilitySummary)
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(12).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                    }.buttonStyle(.bordered)
                        .accessibilityIdentifier("template.\(choice.id)")
                        .contextMenu { Button("添加此类型账号") { model.pickTemplate(choice) } }
                }
            }
        }
    }
}
