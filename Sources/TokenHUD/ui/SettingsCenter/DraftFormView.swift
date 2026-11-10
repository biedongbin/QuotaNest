import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DraftFormView: View {
    enum Section { case config, trigger, all }
    @ObservedObject var model: SettingsModel
    let draft: Draft
    var section: Section = .all
    @State private var revealCallKey = false
    @State private var clearingCallKey = false
    @State private var choosingAuthFile = false
    private var manifest: ProviderManifest? { model.draftManifest() }
    private var builtin: Bool { model.draftBuiltin() }
    private var capability: ProviderCapabilityPresentation {
        ProviderCapabilityPresentation(manifest: manifest, generic: !builtin)
    }
    private var canCall: Bool { capability.canCall(using: draft.values.authMode) }

    var body: some View {
        if model.draftConfigurationReadOnly {
            Label(SettingsModel.sourceReadOnlyMessage, systemImage: "lock")
                .font(.callout).textSelection(.enabled)
        } else {
            editableForm
        }
    }

    private var editableForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("基础接入、用量查询与 API 调度分别设置，保存后生效。"))
                .font(.callout).foregroundStyle(.secondary)
            if section != .trigger {
                identity
                callConnection
                quotaConnection
            }
            if section != .config { schedule }
        }
        .confirmationDialog(L10n.tr("保存后清除基础 API Key？"), isPresented: $clearingCallKey, titleVisibility: .visible) {
            Button(L10n.tr("标记清除"), role: .destructive) {
                model.draft?.values.clearKeyIntent = true
                model.draft?.values.key = ""
            }
            Button(L10n.tr("取消"), role: .cancel) { }
        } message: {
            Text(L10n.tr("用量查询与 API 调度共用基础认证；清除后对应能力将不可用。保存前可以撤销。"))
        }
    }

    private var identity: some View {
        GroupBox(L10n.tr("账号")) {
            VStack(alignment: .leading, spacing: 10) {
                labeled(L10n.tr("账号名称")) {
                    TextField(L10n.tr("账号名称"), text: bind(\.name)).fieldBox()
                        .accessibilityLabel(L10n.tr("账号名称"))
                }
                if let error = model.errors["name"] { Text(error).foregroundStyle(.red).font(.callout) }
                labeled(L10n.tr("供应商类型")) { Text(manifest?.label ?? L10n.tr("自定义兼容 API")).foregroundStyle(Palette.muted) }
            }
        }
    }
    private var callConnection: some View {
        GroupBox(L10n.tr("① 基础接入")) {
            VStack(alignment: .leading, spacing: 12) {
                labeled(L10n.tr("认证方式")) {
                    Picker(L10n.tr("认证方式"), selection: bind(\.authMode)) {
                        Text(capability.allowsAuth ? L10n.tr("Auth · 授权文件") : L10n.tr("Auth · 此类型未接入"))
                            .tag("auth").disabled(!capability.allowsAuth)
                        Text(capability.allowsAPIKey ? "API Key" : L10n.tr("API Key · 此类型未接入"))
                            .tag("apikey").disabled(!capability.allowsAPIKey)
                        if !["auth", "apikey"].contains(draft.values.authMode) {
                            Text(L10n.tr("已保存：") + draft.values.authMode).tag(draft.values.authMode).disabled(true)
                        }
                    }.labelsHidden()
                }
                if let issue = capability.authenticationIssue(for: draft.values.authMode) {
                    Text(issue).font(.callout).foregroundStyle(Palette.warn).textSelection(.enabled)
                }
                if canCall {
                    labeled(L10n.tr("服务地址")) {
                        if draft.values.authMode == "auth" {
                            Text(model.baseAddressDescription(model.callConfigForDraft(draft.values))).font(.callout)
                        } else {
                            TextField("https://api.example.com/v1", text: bind(\.url))
                                .fieldBox().disabled(builtin).accessibilityLabel(L10n.tr("API 服务地址"))
                        }
                    }
                    labeled(L10n.tr("调用协议")) {
                        if draft.values.authMode == "auth" {
                            Text(model.baseProtocolDescription(model.callConfigForDraft(draft.values))).font(.callout)
                        } else {
                            Picker(L10n.tr("调用协议"), selection: bind(\.proto)) {
                                Text("OpenAI Chat Completions").tag("openai")
                                Text("Anthropic Messages").tag("anthropic")
                            }.labelsHidden().disabled(builtin)
                        }
                    }
                    if builtin {
                        Label(L10n.tr("地址与协议由供应商类型提供"), systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label(L10n.tr("当前认证的模型测试与 API 调度未接入"), systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(L10n.tr("可配置已接入的用量查询；此处不会为该类型生成模型调用接口。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.values.authMode == "auth", capability.allowsAuth {
                    labeled(L10n.tr("Auth 文件")) {
                        HStack(spacing: 8) {
                            TextField(L10n.tr("留空使用供应商默认来源"), text: bind(\.authCredentialFile))
                                .fieldBox().accessibilityLabel(L10n.tr("Auth 文件路径"))
                                .accessibilityIdentifier("account.auth-file")
                            Button(L10n.tr("选择…")) { chooseAuthFile() }.barButton()
                                .disabled(choosingAuthFile).accessibilityIdentifier("account.choose-auth-file")
                            Button(L10n.tr("默认")) { model.draft?.values.authCredentialFile = "" }.barButton(.ghost)
                                .disabled(draft.values.authCredentialFile.isEmpty)
                        }
                    }
                    Text(L10n.tr("当前有效来源：") + model.draftAuthSourceDescription())
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(L10n.tr("读取已有本机授权；本页不提供浏览器 OAuth 登录，也无需另填 API Key。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if canCall, let issue = model.authenticationIssue(model.callConfigForDraft(draft.values)) {
                        Text(issue).font(.callout).foregroundStyle(Palette.danger).textSelection(.enabled)
                    }
                } else if draft.values.authMode == "apikey", capability.allowsAPIKey {
                    secret("API Key", value: bind(\.key), revealed: $revealCallKey)
                    credentialActions
                }
                if canCall {
                    labeled(L10n.tr("模型")) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(L10n.tr("例如 claude-sonnet 或 gpt-4.1"), text: bind(\.model))
                                .fieldBox().accessibilityLabel(L10n.tr("调用模型"))
                            ModelCatalogControls(model: model)
                        }
                    }
                    DisclosureGroup(L10n.tr("测试选项")) {
                        labeled(L10n.tr("测试提示词")) {
                            TextField(L10n.tr("只回复 OK"), text: bind(\.prompt)).fieldBox()
                                .accessibilityLabel(L10n.tr("测试提示词"))
                        }.padding(.top, 6)
                    }.font(.system(size: 12)).foregroundStyle(Palette.muted)
                    HStack {
                        Text(L10n.tr("测试使用当前输入，不保存；会消耗额度。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        AccountActionButton(title: model.isTestingCurrentConfig ? L10n.tr("测试中…") : L10n.tr("测试当前 API 配置"),
                                            identifier: "account.test-draft", enabled: !model.isTestingCurrentConfig) {
                            model.testCallDraft(values: model.draft?.values ?? draft.values)
                        }.fixedSize().frame(height: 28)
                    }
                }
                if let result = model.callTestResult(for: nil) { CallTestResultView(result: result) }
            }
        }
    }
    private var quotaConnection: some View {
        GroupBox(L10n.tr("② 用量查询 · 可选")) {
            VStack(alignment: .leading, spacing: 12) {
                labeled(L10n.tr("查询方式")) {
                    Picker(L10n.tr("查询方式"), selection: bind(\.quotaMode)) {
                        Text(L10n.tr("关闭用量查询")).tag("none")
                        if builtin { Text(L10n.tr("供应商查询")).tag("script").disabled(manifest?.supportsQuota != true) }
                        else { Text(L10n.tr("查询接口")).tag("endpoint") }
                    }.labelsHidden()
                }
                if draft.values.quotaMode != "none" {
                    labeled(L10n.tr("查询认证")) {
                        Text(draft.values.authMode == "auth" ? L10n.tr("跟随基础接入 · Auth") : L10n.tr("跟随基础接入 · API Key"))
                    }
                    Text(L10n.tr("使用基础接入的同一认证，不需要额外填写查询凭证。"))
                        .font(.callout).foregroundStyle(.secondary)
                    if let issue = model.quotaAuthenticationIssue(model.callConfigForDraft(draft.values)) {
                        Text(issue).font(.callout).foregroundStyle(Palette.warn).textSelection(.enabled)
                    }
                    if draft.values.quotaMode == "endpoint" {
                        labeled(L10n.tr("用量查询地址")) {
                            TextField("https://example.com/api/usage", text: bind(\.queryURL))
                                .fieldBox().disabled(builtin).accessibilityLabel(L10n.tr("用量查询地址"))
                        }
                    } else {
                        Label(L10n.tr("查询地址与解析由供应商类型提供"), systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let slug = draft.slug {
                        Button(model.running.contains(slug) ? L10n.tr("查询中…") : L10n.tr("查询已保存配置")) { model.query(slug) }
                            .disabled(model.running.contains(slug) || model.current.map { !model.quotaConfigured($0) } != false)
                        Text(L10n.tr("查询使用已保存配置；先保存当前更改，再查询。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var credentialActions: some View {
        let marked = draft.values.clearKeyIntent
        return HStack {
            Text(marked ? L10n.tr("已标记清除，保存后生效") : L10n.tr("留空保持已有 API Key；新输入替换"))
                .font(.caption).foregroundStyle(marked ? Color.red : Color.secondary)
            Spacer()
            if !draft.isNew {
                Button(marked ? L10n.tr("撤销清除") : L10n.tr("清除 API Key…")) {
                    if marked { model.draft?.values.clearKeyIntent = false }
                    else { clearingCallKey = true }
                }.font(.callout)
            }
        }
    }
    private func chooseAuthFile() {
        guard !choosingAuthFile else { return }
        choosingAuthFile = true
        let openedSlug = model.draft?.slug
        let openedTemplate = model.draft?.template
        let panel = NSOpenPanel()
        panel.title = L10n.tr("选择 Auth 授权文件")
        panel.prompt = L10n.tr("选择")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.allowedContentTypes = [.json]
        let config = model.callConfigForDraft(model.draft?.values ?? draft.values)
        panel.directoryURL = ProviderAuthentication.credentialFileURL(for: config)?.deletingLastPathComponent()
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            choosingAuthFile = false
            guard response == .OK, let url = panel.url,
                  model.draft?.slug == openedSlug, model.draft?.template == openedTemplate else { return }
            model.draft?.values.authCredentialFile = url.path
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private var schedule: some View {
        GroupBox(L10n.tr("③ API 调度 · 启动 5h 使用窗口")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L10n.tr("启用 API 调度"), isOn: bind(\.autoTrigger)).toggleStyle(.switch)
                    .disabled(!canCall && !draft.values.autoTrigger)
                if !canCall {
                    Text(L10n.tr("当前认证的模型调用与调度未接入。已有计划可关闭；用量查询可独立使用。"))
                        .font(.callout).foregroundStyle(Palette.warn)
                }
                Text(L10n.tr("在所设时间尝试主动开启动态 5h 使用窗口，不保证供应商必然开窗。使用基础接入认证，每次会消耗套餐额度。按本机时区 %@ 执行多个时间点；仅按用户设置调用，不推断或自动重置窗口。", String(describing: TimeZone.current.identifier)))
                    .font(.callout).foregroundStyle(.secondary)
                Text(L10n.tr("调度使用当前选择模型：%@。模型必须在目标账号套餐内可调用；请在基础接入中选择并测试。", String(describing: model.draftScheduleModel(draft.values).isEmpty ? L10n.tr("尚未指定") : model.draftScheduleModel(draft.values))))
                    .font(.caption).foregroundStyle(.secondary)
                RecommendedScheduleTimes { preset in
                    model.draft?.values.times = preset
                    model.draft?.timeInput = ""
                    model.errors["time"] = nil
                    model.errors["times"] = nil
                }.disabled(!canCall)
                HStack {
                    TextField("09:00", text: Binding(get: { model.draft?.timeInput ?? "" }, set: { model.draft?.timeInput = $0 }))
                        .fieldBox().frame(width: 100).accessibilityLabel(L10n.tr("添加调用时间，24小时制"))
                        .onSubmit { model.addTime() }
                    Button(L10n.tr("添加时间")) { model.addTime() }
                }.disabled(!canCall)
                ForEach(["time", "times"], id: \.self) { key in
                    if let error = model.errors[key] { Text(error).font(.callout).foregroundStyle(.red) }
                }
                FlowChips(times: draft.values.times) { model.removeTime(at: $0) }
                if draft.values.times.isEmpty { Text(L10n.tr("尚未添加时间点")).foregroundStyle(.secondary) }
            }
        }
    }
    private func bind<T>(_ keyPath: WritableKeyPath<DraftValues, T>) -> Binding<T> {
        Binding(get: { model.draft?.values[keyPath: keyPath] ?? draft.values[keyPath: keyPath] }, set: {
            model.draft?.values[keyPath: keyPath] = $0
        })
    }
    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                    .frame(width: 110, alignment: .trailing)
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func secret(_ label: String, value: Binding<String>, revealed: Binding<Bool>) -> some View {
        labeled(label) {
            HStack {
                Group {
                    if revealed.wrappedValue { TextField(L10n.tr("留空保持原值"), text: value) }
                    else { SecureField(L10n.tr("留空保持原值"), text: value) }
                }.fieldBox().accessibilityLabel(label)
                Button { revealed.wrappedValue.toggle() } label: {
                    Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye")
                }.accessibilityLabel(revealed.wrappedValue ? L10n.tr("隐藏%@", String(describing: label)) : L10n.tr("显示%@", String(describing: label)))
            }
        }
    }
}

struct FlowChips: View {
    let times: [String]
    let onRemove: (Int) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 95), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(Array(times.enumerated()), id: \.offset) { index, time in
                HStack {
                    Text(time).monospacedDigit()
                    Button { onRemove(index) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L10n.tr("删除 %@", String(describing: time)))
                }.padding(6).background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
