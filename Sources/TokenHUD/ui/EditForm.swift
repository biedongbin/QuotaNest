import SwiftUI
import AppKit

// MARK: - 供应商账号编辑窗 (类型模板实例化 / 通用自定义 / 编辑 / 复制)

/// 选类型 -> 填凭证 -> 定时; 固化字段按类型模板锁定, 主框架无 slug switch
struct EditForm: View {
    /// nil = 新建/复制模式
    let p: PluginProvider?
    let hudDir: URL
    let userDir: URL
    let bundleDir: URL?
    let engine: DataEngine
    var isNew: Bool { p == nil }
    var onClose: () -> Void = { EditPanelController.shared.close() }

    @State private var newName = ""
    /// 新建所选类型模板 slug (nil = 通用自定义)
    @State private var selectedTemplateSlug: String?
    /// 复制模式来源
    @State private var copySource: PluginProvider?

    @State private var config: ProviderConfig
    @State private var showQueryKey = false
    @State private var showQueryToken = false
    @State private var showRefreshKey = false
    @State private var queryTestResult: String?
    @State private var refreshTestResult: String?
    @State private var queryTesting = false
    @State private var refreshTesting = false
    /// 测试成功与否 (颜色判据, 不依赖文案魔法前缀)
    @State private var queryTestOK = false
    @State private var refreshTestOK = false

    /// 能力 manifest: 新建看所选类型模板; 编辑看实例自身 (instantiate 已继承模板能力字段)
    private var typeManifest: ProviderManifest? {
        if isNew { return selectedTemplateSlug.flatMap { engine.template(bySlug: $0) }?.manifest }
        return p?.manifest
    }

    /// 脚本型 (固化脚本解析额度): 新建 = 选了类型模板; 编辑 = 实例带 template 字段
    private var isScriptType: Bool {
        if isNew { return selectedTemplateSlug != nil }
        return p?.manifest.template != nil
    }

    /// 查余额凭证类型 (jwt/bearer/cookie/header)
    private var effQueryAuth: String {
        typeManifest?.queryAuth ?? p?.manifest.queryAuth ?? "bearer"
    }

    /// 查余额 url: generic 可配; 脚本型固化 (jwt/bearer/cookie 型隐藏, header 型 gpt 例外——看板 url 是唯一账号配置)
    private var showQueryUrl: Bool { !isScriptType || effQueryAuth == "header" }
    /// 刷新栏可见: generic 自由配; 脚本型看模板有无 refreshUrl (gpt 无刷新触发)
    private var showRefresh: Bool { !isScriptType || typeManifest?.refreshUrl != nil }
    /// 刷新栏 url/协议/header 是否固化 (脚本型锁定, 只填 key/model/prompt)
    private var refreshLocked: Bool { isScriptType }

    init(p: PluginProvider, hudDir: URL, userDir: URL, bundleDir: URL? = nil, engine: DataEngine) {
        self.p = p
        self.hudDir = hudDir
        self.userDir = userDir
        self.bundleDir = bundleDir
        self.engine = engine
        guard let authFile = Self.authURL(for: p, hudDir: hudDir) else {
            _config = State(initialValue: ProviderConfig())
            return
        }
        // 脚本型实例首次编辑: auth 模板兜底 (迁移已建, 此处防手删)
        if let tslug = p.manifest.template,
           let tmpl = engine.template(bySlug: tslug),
           !FileManager.default.fileExists(atPath: authFile.path) {
            _ = try? PluginGenerator.instantiate(template: tmpl, slug: p.slug, name: p.manifest.fullName, into: userDir, hudDir: hudDir)
        }
        _newName = State(initialValue: p.manifest.fullName)
        // testModel 缺省从 manifest 补 (auth 文件首次无此字段)
        var c = ProviderConfigStore.read(authFile: authFile, manifest: p.manifest)
        if c.testModel.isEmpty { c.testModel = p.manifest.refreshModel }
        _config = State(initialValue: c)
    }

    /// 新建模式: 空表单, 类型默认通用自定义
    init(hudDir: URL, userDir: URL, bundleDir: URL? = nil, engine: DataEngine) {
        self.p = nil
        self.hudDir = hudDir
        self.userDir = userDir
        self.bundleDir = bundleDir
        self.engine = engine
        _config = State(initialValue: ProviderConfig())
    }

    /// 复制模式: 预填源实例全部配置, 保存时换名生成新 slug 实例
    init(copy p: PluginProvider, hudDir: URL, userDir: URL, bundleDir: URL? = nil, engine: DataEngine) {
        self.p = nil
        self.hudDir = hudDir
        self.userDir = userDir
        self.bundleDir = bundleDir
        self.engine = engine
        _selectedTemplateSlug = State(initialValue: p.manifest.template)
        _copySource = State(initialValue: p)
        var c = ProviderConfig()
        if let authFile = Self.authURL(for: p, hudDir: hudDir) {
            c = ProviderConfigStore.read(authFile: authFile, manifest: p.manifest)
        }
        _config = State(initialValue: c)
    }

    /// 头部模式徽章: 本机登录 / API Key / OAuth
    private var modeLabel: String {
        switch typeManifest?.authStyle ?? "apikey" {
        case "local": return "本机登录 · 凭证由 CLI 维护"
        case "oauth": return "OAuth 授权"
        default: return "API Key"
        }
    }

    var windowTitle: String {
        if isNew, let cs = copySource { return "复制 — \(cs.manifest.fullName)" }
        if isNew, let t = selectedTemplateSlug.flatMap({ engine.template(bySlug: $0) }) {
            return "添加 — \(t.manifest.fullName) 账号"
        }
        if isNew { return "添加供应商" }
        return "编辑 — \(p!.manifest.fullName)"
    }

    var body: some View {
        let prov = p
        let kindLabel: String = {
            if isNew, let cs = copySource { return "复制 — \(cs.manifest.fullName)" }
            if isNew, let t = selectedTemplateSlug.flatMap({ engine.template(bySlug: $0) }) {
                return "添加 — \(t.manifest.fullName) 账号"
            }
            if isNew { return "添加供应商" }
            return "编辑 — \(prov!.manifest.fullName)"
        }()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                if let prov {
                    ProviderBadge(icon: prov.manifest.icon, label: prov.manifest.label,
                                  accent: brandColor(prov.manifest.accent), size: 30)
                } else if let cs = copySource {
                    ProviderBadge(icon: cs.manifest.icon, label: cs.manifest.label,
                                  accent: brandColor(cs.manifest.accent), size: 30)
                } else if let t = selectedTemplateSlug.flatMap({ engine.template(bySlug: $0) }) {
                    ProviderBadge(icon: t.manifest.icon, label: t.manifest.label,
                                  accent: brandColor(t.manifest.accent), size: 30)
                } else {
                    Image(systemName: "plus.circle.fill").font(.system(size: 24)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(kindLabel).font(.system(.headline, design: .rounded))
                    Text(modeLabel)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            labeledField("名称", TextField("如 my-relay / glm-工作", text: $newName)
                .textFieldStyle(.roundedBorder))
            if isNew {
                labeledField("类型", Picker("", selection: $selectedTemplateSlug) {
                    Text("通用自定义").tag(String?.none)
                    ForEach(engine.templates) { t in
                        Text(t.manifest.fullName).tag(String?.some(t.slug))
                    }
                }
                .pickerStyle(.menu).frame(width: 200))
                Text("脚本型: 凭证/配置固化解析; 通用: url+apikey 查询与触发")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            // 上栏: 查余额 (凭证按类型)
            Group {
                Text("查余额").font(.caption).bold().foregroundStyle(.secondary)
                if showQueryUrl {
                    labeledField("url", TextField(isNew ? "https://…" : "https://…", text: $config.queryUrl)
                        .textFieldStyle(.roundedBorder))
                }
                switch effQueryAuth {
                case "jwt":
                    keyField("accessToken", $config.queryToken, show: $showQueryToken)
                case "cookie":
                    keyField("cookie", $config.queryCookie, show: $showQueryKey)
                case "header":
                    EmptyView()
                default: // bearer (generic)
                    keyField("apiKey", $config.queryKey, show: $showQueryKey)
                }
                if !isScriptType {
                    labeledField("header", TextField("k: v", text: $config.queryHeader)
                        .textFieldStyle(.roundedBorder))
                }
                HStack {
                    Button("测试") { testQuery() }.disabled(queryTesting)
                    if queryTesting { ProgressView().controlSize(.small) }
                    if let queryTestResult {
                        Text(queryTestResult).font(.caption)
                            .foregroundStyle(queryTestOK ? Color.green : Color.orange)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("查余额配置")

            Divider()

            // 下栏: 触发刷新 (脚本型只填 key/model/prompt)
            if showRefresh {
                Group {
                    Text("刷新窗口（触发滚动计算）").font(.caption).bold().foregroundStyle(.secondary)
                    if !refreshLocked {
                        labeledField("API使用协议", Picker("", selection: $config.refreshProtocol) {
                            Text("anthropic").tag("anthropic")
                            Text("openai").tag("openai")
                        }
                        .pickerStyle(.segmented).frame(width: 180))
                        labeledField("url", TextField(isNew ? "https://relay.example.com/v1/chat/completions" : "https://…", text: $config.refreshUrl)
                            .textFieldStyle(.roundedBorder))
                        keyField("apiKey", $config.refreshKey, show: $showRefreshKey)
                        labeledField("header", TextField("k: v", text: $config.refreshHeader)
                            .textFieldStyle(.roundedBorder))
                    } else {
                        keyField("apiKey", $config.refreshKey, show: $showRefreshKey)
                    }
                    labeledField("测试模型", TextField("model", text: $config.testModel)
                        .textFieldStyle(.roundedBorder))
                    labeledField("测试提示词", TextField("prompt", text: $config.testPrompt)
                        .textFieldStyle(.roundedBorder))
                    HStack {
                        Button("测试") { testRefresh() }.disabled(refreshTesting)
                        if refreshTesting { ProgressView().controlSize(.small) }
                        if let refreshTestResult {
                            Text(refreshTestResult).font(.caption)
                                .foregroundStyle(refreshTestOK ? Color.green : Color.orange)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("刷新窗口配置")

                Divider()
            }

            // 定时触发
            Group {
                Text("定时触发").font(.caption).bold().foregroundStyle(.secondary)
                Text("到点自动发一次请求, 触发 5h 滚动计费窗口 (HH:MM, 24h)").font(.caption2).foregroundStyle(.tertiary)
                ForEach(Array(config.scheduleTimes.enumerated()), id: \.offset) { i, t in
                    HStack {
                        TextField("HH:MM", text: $config.scheduleTimes[i])
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                        Button {
                            config.scheduleTimes.remove(at: i)
                        } label: { Image(systemName: "minus.circle").foregroundStyle(.red) }
                            .buttonStyle(.plain)
                    }
                }
                Button {
                    config.scheduleTimes.append("")
                } label: { Label("添加时间点", systemImage: "plus.circle") }
                    .buttonStyle(.plain).font(.caption)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("定时触发配置")

            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .keyboardShortcut(.cancelAction)   // Esc
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)  // Enter
                    .disabled(isNew && (newName.trimmingCharacters(in: .whitespaces).isEmpty
                        || (selectedTemplateSlug == nil && config.queryUrl.isEmpty && config.queryKey.isEmpty)))
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: 表单小组件

    private func labeledField(_ label: String, _ field: some View) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            field
        }
    }

    private func keyField(_ label: String, _ text: Binding<String>, show: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            if show.wrappedValue {
                TextField(label, text: text).textFieldStyle(.roundedBorder)
            } else {
                SecureField(label, text: text).textFieldStyle(.roundedBorder)
            }
            Button {
                show.wrappedValue.toggle()
            } label: {
                Image(systemName: show.wrappedValue ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(show.wrappedValue ? "隐藏" : "显示")
            .accessibilityLabel(show.wrappedValue ? "隐藏\(label)" : "显示\(label)")
        }
    }

    // MARK: 动作

    private func testQuery() {
        queryTesting = true
        queryTestResult = nil
        Task {
            let err = await RefreshTrigger.testQuery(config: config)
            await MainActor.run {
                queryTesting = false
                queryTestOK = (err == nil)
                queryTestResult = err ?? "✓ 查询成功"
            }
        }
    }

    private func testRefresh() {
        refreshTesting = true
        refreshTestResult = nil
        Task {
            let err = await RefreshTrigger.testRefresh(config: config)
            await MainActor.run {
                refreshTesting = false
                refreshTestOK = (err == nil)
                refreshTestResult = err ?? "✓ 触发成功"
            }
        }
    }

    /// HH:MM 格式校验 (24h 制, 分 < 60)
    static func isValidScheduleTime(_ t: String) -> Bool {
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return (0...23).contains(h) && (0...59).contains(m) && parts[0].count == 2 && parts[1].count == 2
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        // HH:MM 校验 (编辑/新建通用)
        if let bad = config.scheduleTimes.first(where: { !Self.isValidScheduleTime($0) }) {
            refreshTestResult = "时间点格式错误: \"\(bad)\" 应为 HH:MM"; refreshTestOK = false; return
        }
        // ---- 新建/复制 ----
        if isNew {
            guard !name.isEmpty else { refreshTestResult = "请填名称"; refreshTestOK = false; return }
            let slug = PluginGenerator.slugify(name)
            let existing = ProviderRegistry.load(bundleDir: bundleDir, userDir: userDir).plugins.map(\.slug)
            if existing.contains(slug) {
                refreshTestResult = "名称冲突: 已存在 \"\(slug)\", 请换名"; refreshTestOK = false; return
            }
            do {
                if let tmpl = selectedTemplateSlug.flatMap({ engine.template(bySlug: $0) }) {
                    // 脚本型: 模板实例化 (manifest 派生 + fetch.sh {SLUG} + auth 模板复制)
                    let manifest = try PluginGenerator.instantiate(template: tmpl, slug: slug, name: name, into: userDir, hudDir: hudDir)
                    let authFile = PluginGenerator.expandPath(manifest.authFile!)
                    try ProviderConfigStore.write(config, manifest: manifest, to: authFile)
                } else {
                    // generic: 生成 manifest + one-api 脚本 + auth
                    let authFilePath = PluginGenerator.authPath(slug: slug, hudDir: hudDir)
                    let manifest = PluginGenerator.customManifest(name: name, config: config, authFile: authFilePath)
                    try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
                    try PluginGenerator.writePlugin(slug: slug, manifest: manifest,
                                                    script: PluginGenerator.oneAPIFetchScript(slug: slug), into: userDir)
                    let authFile = PluginGenerator.expandPath(authFilePath)
                    try ProviderConfigStore.createCustom(slug: slug, to: authFile)
                    try ProviderConfigStore.write(config, manifest: manifest, to: authFile)
                }
                onClose()
                engine.reloadRegistry()
                Task { await engine.refreshNow() }
            } catch {
                refreshTestResult = "保存失败: \(error.localizedDescription)"; refreshTestOK = false
            }
            return
        }
        // ---- 编辑 ----
        guard let prov = p, let authFile = Self.authURL(for: prov, hudDir: hudDir) else { onClose(); return }
        do {
            // generic: 同步重写 manifest (url 等协议字段进 manifest, 否则编辑后查询仍打旧地址) + fetch.sh
            // 脚本型: 脚本固化, 只写凭证/测试字段到 auth
            // 名称可改: slug 固定, 名称=displayName; manifest 同步重写
            let displayName = name.isEmpty ? prov.manifest.fullName : name
            if prov.manifest.template == nil {
                // generic: name/displayName/协议字段全部按当前表单重写
                let manifest = PluginGenerator.customManifest(
                    name: displayName, config: config,
                    authFile: PluginGenerator.authPath(slug: prov.slug, hudDir: hudDir))
                try PluginGenerator.writePlugin(
                    slug: prov.slug, manifest: manifest,
                    script: PluginGenerator.oneAPIFetchScript(slug: prov.slug), into: userDir)
                try ProviderConfigStore.write(config, manifest: manifest, to: authFile)
            } else {
                // 脚本型: manifest 只改 displayName, 固化 fetch.sh 原样保留
                var m = prov.manifest
                m.displayName = displayName
                let script = (try? String(contentsOf: userDir
                    .appendingPathComponent(prov.slug + "/fetch.sh"), encoding: .utf8)) ?? ""
                try PluginGenerator.writePlugin(slug: prov.slug, manifest: m, script: script, into: userDir)
                try ProviderConfigStore.write(config, manifest: m, to: authFile)
            }
            onClose()
            engine.reloadRegistry()
            Task { await engine.refreshNow() }
        } catch {
            refreshTestResult = "保存失败: \(error.localizedDescription)"; refreshTestOK = false
        }
    }

    /// 凭证文件路径: manifest.authFile 展开, 缺省 hudDir/.{slug}-usage-auth.json
    static func authURL(for p: PluginProvider, hudDir: URL) -> URL? {
        if let af = p.manifest.authFile {
            if af.hasPrefix("~") { return URL(fileURLWithPath: NSHomeDirectory() + String(af.dropFirst())) }
            return URL(fileURLWithPath: af)
        }
        return hudDir.appendingPathComponent(".\(p.slug)-usage-auth.json")
    }
}

// MARK: - 单例编辑面板 (.titled: 自带拖动 + 右上角关闭按钮)

@MainActor
final class EditPanelController {
    static let shared = EditPanelController()
    private var panel: NSPanel?

    /// 打开 (或复用) 编辑窗口 — 全局仅一个实例, 重复点击只换内容
    func show(_ form: EditForm) {
        let hosting = NSHostingView(rootView: form)
        hosting.layoutSubtreeIfNeeded()
        if let panel {
            panel.title = form.windowTitle
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
            panel.orderFrontRegardless()
        } else {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: hosting.fittingSize.width, height: hosting.fittingSize.height),
                            styleMask: [.titled, .closable, .resizable],
                            backing: .buffered, defer: false)
            p.title = form.windowTitle
            p.isReleasedWhenClosed = false
            p.level = .floating
            p.minSize = NSSize(width: hosting.fittingSize.width, height: 200)
            p.setFrameAutosaveName("editPanel") // 位置/大小记忆
            p.contentView = hosting
            if p.frame.size.width < hosting.fittingSize.width {
                p.setContentSize(hosting.fittingSize)
            }
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            panel = p
        }
    }

    func close() {
        panel?.orderOut(nil)
    }
}
