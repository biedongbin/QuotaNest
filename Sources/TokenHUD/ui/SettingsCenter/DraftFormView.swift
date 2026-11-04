import SwiftUI

struct DraftFormView: View {
    enum Section { case config, trigger, all }
    @ObservedObject var model: SettingsModel
    let draft: Draft
    var section: Section = .all
    @State private var revealCallKey = false
    @State private var revealQueryKey = false
    @State private var revealQueryToken = false
    @State private var revealQueryCookie = false
    @State private var clearing: CredentialKind?
    private enum CredentialKind: String, Identifiable { case call, query; var id: String { rawValue } }
    private var manifest: ProviderManifest? { model.draftManifest() }
    private var builtin: Bool { model.draftBuiltin() }

    var body: some View {
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
        .confirmationDialog(clearing == .call ? "保存后清除 API 调用凭证？" : "保存后清除额度查询凭证？",
                            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), titleVisibility: .visible) {
            Button("标记清除", role: .destructive) {
                if clearing == .call {
                    model.draft?.values.clearKeyIntent = true
                    model.draft?.values.key = ""
                } else {
                    model.draft?.values.clearQueryKeyIntent = true
                    model.draft?.values.queryKey = ""
                    model.draft?.values.queryToken = ""
                    model.draft?.values.queryCookie = ""
                }
                clearing = nil
            }
            Button("取消", role: .cancel) { clearing = nil }
        } message: {
            Text("清除基础 API Key 后，跟随基础接入的查询也将不可用。旧版独立查询凭证会保留；保存前可以撤销。")
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
                        Text("Auth · 本机授权").tag("auth")
                        Text("API Key").tag("apikey")
                    }.labelsHidden()
                }
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
                if draft.values.authMode == "auth" {
                    labeled("授权来源 / 文件") {
                        Text(model.draftAuthSourceDescription()).font(.callout).textSelection(.enabled)
                    }
                    Text("读取已有本机授权；本页不提供浏览器 OAuth 登录，也无需另填 API Key。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let issue = model.authenticationIssue(model.callConfigForDraft(draft.values)) {
                        Text(issue).font(.callout).foregroundStyle(Palette.danger).textSelection(.enabled)
                    }
                } else {
                    secret("API Key", value: bind(\.key), revealed: $revealCallKey)
                    credentialActions(query: false)
                }
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
                        if builtin { Text("供应商查询").tag("script") }
                        else { Text("查询接口").tag("endpoint") }
                    }.labelsHidden()
                }
                if draft.values.quotaMode != "none" {
                    labeled("查询认证") {
                        Picker("查询认证", selection: bind(\.quotaCredentialMode)) {
                            Text("跟随基础接入（默认）").tag("inherit")
                            if model.draftHasLegacyCredentials() || draft.values.quotaCredentialMode == "legacy" {
                                Text("旧版独立凭证").tag("legacy")
                            }
                        }.labelsHidden()
                    }
                    Text(draft.values.quotaCredentialMode == "inherit"
                         ? "使用基础接入的同一认证；基础凭证失效或被清除后，查询也不可用。"
                         : "当前仍使用旧版独立查询凭证，可切换为跟随基础接入；切换不会删除旧凭证。")
                        .font(.callout).foregroundStyle(.secondary)
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
                if model.draftHasLegacyCredentials() || draft.values.quotaCredentialMode == "legacy" {
                    DisclosureGroup("旧版查询兼容") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("仅保留历史网页 Access Token / Cookie 等独立凭证。建议切换为跟随基础接入；不会静默删除旧值。")
                                .font(.caption).foregroundStyle(.secondary)
                            quotaCredentials
                            credentialActions(query: true)
                        }.padding(.top, 8)
                    }
                }
            }
        }
    }
    @ViewBuilder private var quotaCredentials: some View {
        if manifest?.authStyle != "apikey", builtin, draft.values.quotaMode == "script" {
            Text("由本机授权来源提供。可选凭证只用于该账号查询，不会更改外部 CLI 登录。")
                .font(.callout).foregroundStyle(.secondary)
        }
        switch manifest?.queryAuth {
        case "jwt": secret("额度查询 Token", value: bind(\.queryToken), revealed: $revealQueryToken)
        case "cookie": secret("额度查询 Cookie", value: bind(\.queryCookie), revealed: $revealQueryCookie)
        default: secret("额度查询 Key", value: bind(\.queryKey), revealed: $revealQueryKey)
        }
        if draft.values.quotaMode == "script", manifest?.queryAuth != "cookie" {
            secret("查询 Cookie（可选）", value: bind(\.queryCookie), revealed: $revealQueryCookie)
            Text("仅用于脚本支持的查询方式；配置状态不代表已验证服务连接。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func credentialActions(query: Bool) -> some View {
        let marked = query ? draft.values.clearQueryKeyIntent : draft.values.clearKeyIntent
        return HStack {
            Text(marked ? "已标记清除，保存后生效" : "留空保持已有凭证；新输入替换对应凭证")
                .font(.caption).foregroundStyle(marked ? Color.red : Color.secondary)
            Spacer()
            if !draft.isNew {
                Button(marked ? "撤销清除" : "清除凭证…") {
                    if marked {
                        if query { model.draft?.values.clearQueryKeyIntent = false }
                        else { model.draft?.values.clearKeyIntent = false }
                    } else { clearing = query ? .query : .call }
                }.font(.callout)
            }
        }
    }
    private var schedule: some View {
        GroupBox("③ API 调度 · 启动 5h 使用窗口") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("启用 API 调度", isOn: bind(\.autoTrigger)).toggleStyle(.switch)
                Text("在所设时间首次调用以启动动态 5h 使用窗口，尽量覆盖工作时段。使用基础接入认证，每次会消耗套餐额度。按本机时区 \(TimeZone.current.identifier) 执行多个时间点；仅按用户设置调用，不推断或自动重置窗口。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("调度使用当前选择模型：\(draft.values.model.isEmpty ? "尚未指定" : draft.values.model)。模型必须在目标账号套餐内可调用；请在基础接入中选择并测试。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("09:00", text: Binding(get: { model.draft?.timeInput ?? "" }, set: { model.draft?.timeInput = $0 }))
                        .fieldBox().frame(width: 100).accessibilityLabel("添加调用时间，24小时制")
                        .onSubmit { model.addTime() }
                    Button("添加时间") { model.addTime() }
                }
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
