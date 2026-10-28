import SwiftUI
import AppKit

// MARK: - 供应商管理 (三版布局可切换)

enum ManagerLayout: String, CaseIterable, Identifiable {
    case split, grid, dense
    var id: String { rawValue }
    var label: String {
        switch self {
        case .split: return "侧栏"
        case .grid: return "卡片"
        case .dense: return "清单"
        }
    }
    var symbol: String {
        switch self {
        case .split: return "sidebar.left"
        case .grid: return "square.grid.2x2"
        case .dense: return "list.bullet"
        }
    }
}

/// 供应商运行状态 (由 cache 推导, UI 各处统一)
enum ProviderStatus {
    case ok, stale, needsAuth, error, idle
    var text: String {
        switch self {
        case .ok: return "正常"
        case .stale: return "过期"
        case .needsAuth: return "需登录"
        case .error: return "错误"
        case .idle: return "未启用"
        }
    }
    var color: Color {
        switch self {
        case .ok: return .green
        case .stale: return .secondary
        case .needsAuth: return .yellow
        case .error: return .red
        case .idle: return Color.secondary.opacity(0.4)
        }
    }
    static func of(_ st: ProviderState?) -> ProviderStatus {
        guard let st, let c = st.cache else { return .idle }
        if c.error == "auth" { return .needsAuth }
        if c.error != nil { return .error }
        return st.isStale ? .stale : .ok
    }
}

struct ProviderManagerView: View {
    @ObservedObject var engine: DataEngine
    let hudDir: URL
    let userDir: URL
    let settingsURL: URL
    let bundleDir: URL?
    /// 离屏渲染自检用: 强制某版布局 (nil = 跟随用户选择)
    var layoutOverride: ManagerLayout? = nil

    @AppStorage("tokenhud.managerLayout") private var layoutRaw = ManagerLayout.split.rawValue
    @State private var selected: String?
    @State private var search = ""
    @State private var filter: ModeFilter = .all
    @State private var importing = false
    @State private var toast: String?

    private var layout: ManagerLayout { layoutOverride ?? ManagerLayout(rawValue: layoutRaw) ?? .split }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .overlay(alignment: .bottom) { toastBar }
        .sheet(isPresented: $importing) {
            ImportSheet(engine: engine, hudDir: hudDir, userDir: userDir) { msg in
                importing = false
                flash(msg)
            }
        }
    }

    // MARK: 工具条

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("供应商").font(.system(.title3, design: .rounded).weight(.semibold))
            Text("\(visible.count)").font(.caption).foregroundStyle(.secondary)

            Spacer(minLength: 8)

            searchField
            Picker("", selection: $filter) {
                ForEach(ModeFilter.allCases) { f in Text(f.label).tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)

            Picker("", selection: $layoutRaw) {
                ForEach(ManagerLayout.allCases) { l in
                    Label(l.label, systemImage: l.symbol).tag(l.rawValue)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            .help("切换布局: 侧栏 / 卡片 / 清单")

            Menu {
                Button("一键导入 (9router / cc-switch / cpamp)…") { importing = true }
                    .help("读取本机其他管理器的已有凭证, 预览后勾选导入")
                Divider()
                Button("写入 Claude Code HUD") { syncHUD() }
                Button("node 定位…") { pickNode() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("导入 / 写入 HUD / node 定位")

            Button {
                openEditor(nil)
            } label: { Label("添加", systemImage: "plus") }
                .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("搜索", text: $search).textFieldStyle(.plain).font(.callout)
                .frame(width: 110)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .split: SplitLayout(engine: engine, rows: visible, selected: $selected,
                                 hudDir: hudDir, userDir: userDir, bundleDir: bundleDir, onToast: flash)
        case .grid:  GridLayout(engine: engine, rows: visible,
                                hudDir: hudDir, userDir: userDir, bundleDir: bundleDir, onToast: flash)
        case .dense: DenseLayout(engine: engine, rows: visible,
                                 hudDir: hudDir, userDir: userDir, bundleDir: bundleDir, onToast: flash)
        }
    }

    @ViewBuilder
    private var toastBar: some View {
        if let toast {
            Text(toast)
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .padding(.bottom, 12)
                .transition(.opacity)
        }
    }

    // MARK: 数据

    private var visible: [ManagerRow] {
        engine.allPlugins
            .filter { p in
                if case .apikey = filter, p.manifest.authStyle != "apikey" { return false }
                if case .local = filter, p.manifest.authStyle == "apikey" { return false }
                guard !search.isEmpty else { return true }
                return p.manifest.fullName.localizedCaseInsensitiveContains(search)
                    || p.slug.localizedCaseInsensitiveContains(search)
            }
            .sorted { a, b in
                let ao = engine.providerOrder.firstIndex(of: a.slug) ?? Int.max
                let bo = engine.providerOrder.firstIndex(of: b.slug) ?? Int.max
                return ao == bo ? a.slug < b.slug : ao < bo
            }
            .map { p in
                ManagerRow(plugin: p,
                           state: engine.states.first { $0.slug == p.slug },
                           enabled: !engine.disabledSlugs.contains(p.slug))
            }
    }

    // MARK: 动作

    private func openEditor(_ p: PluginProvider?) {
        if let p {
            EditPanelController.shared.show(EditForm(p: p, hudDir: hudDir, userDir: userDir,
                                                     bundleDir: bundleDir, engine: engine))
        } else {
            EditPanelController.shared.show(EditForm(hudDir: hudDir, userDir: userDir,
                                                     bundleDir: bundleDir, engine: engine))
        }
    }

    private func flash(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation { toast = nil }
        }
    }

    private func syncHUD() {
        do {
            engine.installScripts()
            let plugins = engine.allPlugins
            let builtin = Set(plugins.filter { $0.manifest.template != nil }.map { $0.manifest.name })
            let new = HUDSync.envsDict(plugins: plugins, hudDir: hudDir, builtinNames: builtin)
            let envsURL = hudDir.appendingPathComponent("envs.json")
            let existing = (try? Data(contentsOf: envsURL))
                .flatMap { try? JSONDecoder().decode([String: EnvsEntry].self, from: $0) } ?? [:]
            try HUDSync.writeEnvs(HUDSync.mergeEnvs(existing: existing, new: new, builtinNames: builtin),
                                  to: envsURL)
            let keys = plugins.filter { $0.manifest.isEnabled && !engine.disabledSlugs.contains($0.slug) }
                .map(\.manifest.name)
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
            let current = (settings?["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String
            try HUDSync.patchSettings(settingsURL: settingsURL,
                                      accountEnvs: HUDSync.mergeAccountEnvs(current: current, keys: keys),
                                      statuslinePath: hudDir.appendingPathComponent("statusline.mjs").path)
            flash("✓ 已写入 Claude Code HUD (下次渲染生效)")
        } catch {
            flash("✗ \(error.localizedDescription)")
        }
    }

    private func pickNode() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: DataEngine.defaultsNodeKey)
            flash("node 路径已保存, 重启 App 生效")
        }
    }
}

// MARK: - 行模型

struct ManagerRow: Identifiable {
    let plugin: PluginProvider
    let state: ProviderState?
    let enabled: Bool
    var id: String { plugin.slug }
    var status: ProviderStatus { enabled ? ProviderStatus.of(state) : .idle }
    var worst: Double? { state?.worstPct }
    var buckets: [(String, Bucket)] {
        var out: [(String, Bucket)] = []
        if let b = state?.cache?.fiveHour, let l = plugin.manifest.buckets["five_hour"] { out.append((l, b)) }
        if let b = state?.cache?.sevenDay, let l = plugin.manifest.buckets["seven_day"] { out.append((l, b)) }
        if let b = state?.cache?.monthly, let l = plugin.manifest.buckets["monthly"] { out.append((l, b)) }
        return out
    }
    var isLocal: Bool { plugin.manifest.authStyle != "apikey" }
}

enum ModeFilter: String, CaseIterable, Identifiable {
    case all, apikey, local
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "全部"
        case .apikey: return "API Key"
        case .local: return "本机登录"
        }
    }
}
