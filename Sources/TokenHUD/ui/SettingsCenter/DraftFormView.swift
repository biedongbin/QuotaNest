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
            Text("基础接入、用量查询与 API 调度分别设置，保存后生效。")
                .font(.callout).foregroundStyle(.secondary)
            if section != .trigger {
                identity
                callConnection
                quotaConnection
            }
            if section != .config { schedule }
        }
        .confirmationDialog("保存后清除基础 API Key？", isPresented: $clearingCallKey, titleVisibility: .visible) {
            Button("标记清除", role: .destructive) {
                model.draft?.values.clearKeyIntent = true
                model.draft?.values.key = ""
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("用量查询与 API 调度共用基础认证；清除后对应能力将不可用。保存前可以撤销。")
        }
    }

    private var identity: some View {
        GroupBox("账号") {
            VStack(alignment: .leading, spacing: 10) {
                labeled("账号名称") {
                    TextField("账号名称", text: bind(\.name)).fieldBox()
                        .accessibilityLabel("账号名称")
                }
                if let error = model.errors["name"] { Text(error).foregroundStyle(.red).font(.callout) }
                labeled("供应商类型") { Text(manifest?.label ?? "自定义兼容 API").foregroundStyle(Palette.muted) }
            }
        }
    }
    private var callConnection: some View {
        GroupBox("① 基础接入") {
            VStack(alignment: .leading, spacing: 12) {
                labeled("认证方式") {
                    Picker("认证方式", selection: bind(\.authMode)) {
                        Text(capability.allowsAuth ? "Auth · 授权文件" : "Auth · 此类型未接入")
                            .tag("auth").disabled(!capability.allowsAuth)
                        Text(capability.allowsAPIKey ? "API Key" : "API Key · 此类型未接入")
                            .tag("apikey").disabled(!capability.allowsAPIKey)
                        if !["auth", "apikey"].contains(draft.values.authMode) {
                            Text("已保存：" + draft.values.authMode).tag(draft.values.authMode).disabled(true)
                        }
                    }.labelsHidden()
                }
                if let issue = capability.authenticationIssue(for: draft.values.authMode) {
                    Text(issue).font(.callout).foregroundStyle(Palette.warn).textSelection(.enabled)
                }
                if canCall {
                    labeled("服务地址") {
                        if draft.values.authMode == "auth" {
                            Text(model.baseAddressDescription(model.callConfigForDraft(draft.values))).font(.callout)
                        } else {
                            TextField("https://api.example.com/v1", text: bind(\.url))
                                .fieldBox().disabled(builtin).accessibilityLabel("API 服务地址")
                        }
                    }
                    labeled("调用协议") {
                        if draft.values.authMode == "auth" {
                            Text(model.baseProtocolDescription(model.callConfigForDraft(draft.values))).font(.callout)
                        } else {
                            Picker("调用协议", selection: bind(\.proto)) {
                                Text("OpenAI Chat Completions").tag("openai")
                                Text("Anthropic Messages").tag("anthropic")
                            }.labelsHidden().disabled(builtin)
                        }
                    }
                    if builtin {
                        Label("地址与协议由供应商类型提供", systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label("当前认证的模型测试与 API 调度未接入", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("可配置已接入的用量查询；此处不会为该类型生成模型调用接口。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.values.authMode == "auth", capability.allowsAuth {
                    labeled("Auth 文件") {
                        HStack(spacing: 8) {
                            TextField("留空使用供应商默认来源", text: bind(\.authCredentialFile))
                                .fieldBox().accessibilityLabel("Auth 文件路径")
                                .accessibilityIdentifier("account.auth-file")
                            Button("选择…") { chooseAuthFile() }.barButton()
                                .disabled(choosingAuthFile).accessibilityIdentifier("account.choose-auth-file")
                            Button("默认") { model.draft?.values.authCredentialFile = "" }.barButton(.ghost)
                                .disabled(draft.values.authCredentialFile.isEmpty)
                        }
                    }
                    Text("当前有效来源：" + model.draftAuthSourceDescription())
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("读取已有本机授权；本页不提供浏览器 OAuth 登录，也无需另填 API Key。")
                        .font(.caption).foregroundStyle(.secondary)
                    if canCall, let issue = model.authenticationIssue(model.callConfigForDraft(draft.values)) {
                        Text(issue).font(.callout).foregroundStyle(Palette.danger).textSelection(.enabled)
                    }
                } else if draft.values.authMode == "apikey", capability.allowsAPIKey {
                    secret("API Key", value: bind(\.key), revealed: $revealCallKey)
                    credentialActions
                }
                if canCall {
                    labeled("模型") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("例如 claude-sonnet 或 gpt-4.1", text: bind(\.model))
                                .fieldBox().accessibilityLabel("调用模型")
                            ModelCatalogControls(model: model)
                        }
                    }
                    DisclosureGroup("测试选项") {
                        labeled("测试提示词") {
                            TextField("只回复 OK", text: bind(\.prompt)).fieldBox()
                                .accessibilityLabel("测试提示词")
                        }.padding(.top, 6)
                    }.font(.system(size: 12)).foregroundStyle(Palette.muted)
                    HStack {
                        Text("测试使用当前输入，不保存；会消耗额度。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        AccountActionButton(title: model.isTestingCurrentConfig ? "测试中…" : "测试当前 API 配置",
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
        GroupBox("② 用量查询 · 可选") {
            VStack(alignment: .leading, spacing: 12) {
                labeled("查询方式") {
                    Picker("查询方式", selection: bind(\.quotaMode)) {
                        Text("关闭用量查询").tag("none")
                        if builtin { Text("供应商查询").tag("script").disabled(manifest?.supportsQuota != true) }
                        else { Text("查询接口").tag("endpoint") }
                    }.labelsHidden()
                }
                if draft.values.quotaMode != "none" {
                    labeled("查询认证") {
                        Text(draft.values.authMode == "auth" ? "跟随基础接入 · Auth" : "跟随基础接入 · API Key")
                    }
                    Text("使用基础接入的同一认证，不需要额外填写查询凭证。")
                        .font(.callout).foregroundStyle(.secondary)
                    if let issue = model.quotaAuthenticationIssue(model.callConfigForDraft(draft.values)) {
                        Text(issue).font(.callout).foregroundStyle(Palette.warn).textSelection(.enabled)
                    }
                    if draft.values.quotaMode == "endpoint" {
                        labeled("用量查询地址") {
                            TextField("https://example.com/api/usage", text: bind(\.queryURL))
                                .fieldBox().disabled(builtin).accessibilityLabel("用量查询地址")
                        }
                    } else {
                        Label("查询地址与解析由供应商类型提供", systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let slug = draft.slug {
                        Button(model.running.contains(slug) ? "查询中…" : "查询已保存配置") { model.query(slug) }
                            .disabled(model.running.contains(slug) || model.current.map { !model.quotaConfigured($0) } != false)
                        Text("查询使用已保存配置；先保存当前更改，再查询。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var credentialActions: some View {
        let marked = draft.values.clearKeyIntent
        return HStack {
            Text(marked ? "已标记清除，保存后生效" : "留空保持已有 API Key；新输入替换")
                .font(.caption).foregroundStyle(marked ? Color.red : Color.secondary)
            Spacer()
            if !draft.isNew {
                Button(marked ? "撤销清除" : "清除 API Key…") {
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
        panel.title = "选择 Auth 授权文件"
        panel.prompt = "选择"
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
        GroupBox("③ API 调度 · 启动 5h 使用窗口") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("启用 API 调度", isOn: bind(\.autoTrigger)).toggleStyle(.switch)
                    .disabled(!canCall && !draft.values.autoTrigger)
                if !canCall {
                    Text("当前认证的模型调用与调度未接入。已有计划可关闭；用量查询可独立使用。")
                        .font(.callout).foregroundStyle(Palette.warn)
                }
                Text("在所设时间尝试主动开启动态 5h 使用窗口，不保证供应商必然开窗。使用基础接入认证，每次会消耗套餐额度。按本机时区 \(TimeZone.current.identifier) 执行多个时间点；仅按用户设置调用，不推断或自动重置窗口。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("调度使用当前选择模型：\(draft.values.model.isEmpty ? "尚未指定" : draft.values.model)。模型必须在目标账号套餐内可调用；请在基础接入中选择并测试。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("09:00", text: Binding(get: { model.draft?.timeInput ?? "" }, set: { model.draft?.timeInput = $0 }))
                        .fieldBox().frame(width: 100).accessibilityLabel("添加调用时间，24小时制")
                        .onSubmit { model.addTime() }
                    Button("添加时间") { model.addTime() }
                }.disabled(!canCall)
                ForEach(["time", "times"], id: \.self) { key in
                    if let error = model.errors[key] { Text(error).font(.callout).foregroundStyle(.red) }
                }
                FlowChips(times: draft.values.times) { model.removeTime(at: $0) }
                if draft.values.times.isEmpty { Text("尚未添加时间点").foregroundStyle(.secondary) }
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
                    if revealed.wrappedValue { TextField("留空保持原值", text: value) }
                    else { SecureField("留空保持原值", text: value) }
                }.fieldBox().accessibilityLabel(label)
                Button { revealed.wrappedValue.toggle() } label: {
                    Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye")
                }.accessibilityLabel(revealed.wrappedValue ? "隐藏\(label)" : "显示\(label)")
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
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("删除 \(time)")
                }.padding(6).background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
