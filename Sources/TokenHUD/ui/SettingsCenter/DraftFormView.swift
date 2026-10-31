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
        VStack(alignment: .leading, spacing: 18) {
            Text("连接与计划修改保存后生效；账号启停和展示开关即时生效。API 与额度查询使用各自的凭证。")
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
            Text("另一组凭证不会改变；保存前可以撤销。")
        }
    }
    private var identity: some View {
        GroupBox("账号") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("账号名称", text: bind(\.name)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("账号名称")
                if let error = model.errors["name"] { Text(error).foregroundStyle(.red).font(.callout) }
                LabeledContent("供应商类型", value: manifest?.label ?? "自定义兼容 API")
                Text("账号名称用于菜单、悬浮窗与 HUD；同一类型可以添加多个账号。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
    private var callConnection: some View {
        GroupBox("API 调用") {
            VStack(alignment: .leading, spacing: 12) {
                labeled("服务地址") {
                    TextField("https://api.example.com/v1", text: bind(\.url))
                        .textFieldStyle(.roundedBorder).disabled(builtin)
                        .accessibilityLabel("API 服务地址")
                }
                Picker("调用协议", selection: bind(\.proto)) {
                    Text("OpenAI Chat Completions").tag("openai")
                    Text("Anthropic Messages").tag("anthropic")
                }.disabled(builtin)
                if builtin {
                    Label("地址与协议由供应商类型提供", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                secret("API Key", value: bind(\.key), revealed: $revealCallKey)
                credentialActions(query: false)
                labeled("模型") {
                    TextField("例如 claude-sonnet 或 gpt-4.1", text: bind(\.model))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("调用模型")
                }
                labeled("测试提示词") {
                    TextField("只回复 OK", text: bind(\.prompt)).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("测试提示词")
                }
                HStack {
                    Text("使用当前输入，不保存配置。发送一次调用会消耗额度。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    AccountActionButton(title: model.isTestingCurrentConfig ? "测试中…" : "测试当前 API 配置",
                                        identifier: "account.test-draft", enabled: !model.isTestingCurrentConfig) {
                        model.testCallDraft(values: model.draft?.values ?? draft.values)
                    }.fixedSize().frame(height: 28)
                }
                if let result = model.callTestResult(for: nil) { CallTestResultView(result: result) }
            }.padding(8)
        }
    }
    private var quotaConnection: some View {
        GroupBox("额度查询 · 可选") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("查询方式", selection: bind(\.quotaMode)) {
                    Text("不查询额度").tag("none")
                    Text("查询接口").tag("endpoint")
                    if builtin { Text("供应商脚本").tag("script") }
                }.disabled(builtin)
                if draft.values.quotaMode == "none" {
                    Text("此账号只用于 API 调用与计划。不开启额度查询也可保存和使用。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    if draft.values.quotaMode == "endpoint" {
                        labeled("额度查询地址") {
                            TextField("https://example.com/api/usage", text: bind(\.queryURL))
                                .textFieldStyle(.roundedBorder).disabled(builtin)
                                .accessibilityLabel("额度查询地址")
                        }
                    } else {
                        Label("查询逻辑由内置供应商脚本提供", systemImage: "lock")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    quotaCredentials
                    credentialActions(query: true)
                    if !builtin {
                        Text("使用独立 Bearer Key 查询此精确地址。接口需返回规范额度 JSON；5 小时、周、月窗口与重置时间均可缺省。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let slug = draft.slug {
                        Button(model.running.contains(slug) ? "查询中…" : "查询已保存配置") { model.query(slug) }
                            .disabled(model.running.contains(slug) || model.current.map { !model.quotaConfigured($0) } != false)
                        Text("额度查询使用已保存配置；先保存新凭证，再查询。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(8)
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
        GroupBox("模型定时调用") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("启用调用计划", isOn: bind(\.autoTrigger)).toggleStyle(.switch)
                Text("使用 API 调用配置，独立于额度查询；按本机时区 \(TimeZone.current.identifier) 执行。每次调用会消耗额度。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("09:00", text: Binding(get: { model.draft?.timeInput ?? "" }, set: { model.draft?.timeInput = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 100).accessibilityLabel("添加调用时间，24小时制")
                        .onSubmit { model.addTime() }
                    Button("添加时间") { model.addTime() }
                }
                ForEach(["time", "times"], id: \.self) { key in
                    if let error = model.errors[key] { Text(error).font(.callout).foregroundStyle(.red) }
                }
                FlowChips(times: draft.values.times) { model.removeTime(at: $0) }
                if draft.values.times.isEmpty { Text("尚未添加时间点").foregroundStyle(.secondary) }
            }.padding(8)
        }
    }
    private func bind<T>(_ keyPath: WritableKeyPath<DraftValues, T>) -> Binding<T> {
        Binding(get: { model.draft?.values[keyPath: keyPath] ?? draft.values[keyPath: keyPath] }, set: {
            model.draft?.values[keyPath: keyPath] = $0
        })
    }
    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).font(.callout).foregroundStyle(.secondary); content() }
    }
    private func secret(_ label: String, value: Binding<String>, revealed: Binding<Bool>) -> some View {
        labeled(label) {
            HStack {
                Group {
                    if revealed.wrappedValue { TextField("留空保持原值", text: value) }
                    else { SecureField("留空保持原值", text: value) }
                }.textFieldStyle(.roundedBorder).accessibilityLabel(label)
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
