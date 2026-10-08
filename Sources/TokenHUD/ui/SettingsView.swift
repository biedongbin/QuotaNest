import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var engine: DataEngine
    let hudDir: URL
    let userDir: URL
    let settingsURL: URL
    let bundleDir: URL?

    @State private var syncResult: String?
    // 额度刷新: 行内反馈 (就近显示, 不藏窗底)
    @State private var refreshingSlug: String?
    @State private var refreshResult: String?
    @State private var refreshResultSlug: String?
    @State private var refreshResultOK = false
    @State private var hoveredSlug: String?
    /// 待删除确认的供应商 (confirmationDialog)
    @State private var pendingDelete: PluginProvider?

    var body: some View {
        Form {
            Section {

                ForEach(allProviders, id: \.slug) { p in
                    providerRow(p)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(hoveredSlug == p.slug ? Color.primary.opacity(0.05) : .clear)
                        )
                        .onHover { hovering in hoveredSlug = hovering ? p.slug : nil }
                        .contextMenu {
                            if p.manifest.authFile != nil {
                                Button("编辑…") { editProvider(p) }
                                Button("复制账号…") { duplicateProvider(p) }
                            }
                            Button("刷新额度") { triggerRefresh(p) }
                            Divider()
                            Button("删除", role: .destructive) { pendingDelete = p }
                        }
                }
                ForEach(engine.registryErrors.sorted(by: { $0.key < $1.key }), id: \.key) { slug, msg in
                    HStack { Text(slug).foregroundStyle(.orange); Text(msg).font(.caption) }
                }
            } header: {
                HStack {
                    Text("供应商")
                    Spacer()
                    Button {
                        EditPanelController.shared.show(
                            EditForm(hudDir: hudDir, userDir: userDir, bundleDir: bundleDir, engine: engine))
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .controlSize(.small)
                    .help("添加自定义供应商 (one-api / OpenAI 兼容)")
                }
            }

            Section("写入 Claude Code HUD") {
                Button("写入 Claude Code HUD") { syncHUD() }
                if let syncResult { Text(syncResult).font(.caption) }
            }

            Section("环境") {
                HStack {
                    Text("node: \(engine.nodeMissing ? "未找到" : "已定位")")
                    Button("手动指定…") { pickNode() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 440) // 可缩放 (HIG 2.1)
        .confirmationDialog("删除供应商 \"\(pendingDelete?.manifest.fullName ?? "")\"?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除 (含凭证与插件文件)", role: .destructive) {
                if let p = pendingDelete { delete(p.slug) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("将移除插件目录与 ~/.claude/hud 下的凭证文件引用, 不可撤销")
        }
    }

    /// 单个供应商行 (徽标 + 名称/副标题 + 操作按钮 + 行内刷新反馈)
    @ViewBuilder
    private func providerRow(_ p: PluginProvider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("拖动排序")
                    .onDrag { NSItemProvider(object: p.slug as NSString) }
                    .onDrop(of: [.text], delegate: ProviderDropDelegate(slug: p.slug, all: allProviders.map(\.slug), onMove: moveTo))
                ProviderBadge(icon: p.manifest.icon, label: p.manifest.label,
                              accent: brandColor(p.manifest.accent), size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.manifest.fullName).font(.system(.callout, design: .rounded).weight(.medium))
                    Text(p.slug).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if refreshingSlug == p.slug {
                    ProgressView().controlSize(.small)
                } else if refreshResultSlug == p.slug, let refreshResult {
                    Text(refreshResult).font(.caption)
                        .foregroundStyle(refreshResultOK ? Color.green : Color.orange)
                } else if let st = engine.states.first(where: { $0.slug == p.slug }) {
                    PctText(pct: st.worstPct, size: 14, weight: .bold)
                }
                Toggle("", isOn: Binding(
                    get: { !engine.disabledSlugs.contains(p.slug) },
                    set: { engine.setTracking(p.slug, enabled: $0) }
                ))
                .labelsHidden()
                .accessibilityLabel("跟踪 \(p.manifest.fullName)")
                if p.manifest.authFile != nil {
                    Button("编辑") { editProvider(p) }
                        .buttonStyle(.borderless).font(.caption)
                }
                Button("刷新额度") { triggerRefresh(p) }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(refreshingSlug == p.slug)
                Button("删除", role: .destructive) { pendingDelete = p }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private func editProvider(_ p: PluginProvider) {
        EditPanelController.shared.show(EditForm(p: p, hudDir: hudDir, userDir: userDir, bundleDir: bundleDir, engine: engine))
    }

    /// 复制账号: 预填源实例配置的添加窗, 换名保存为新 slug 实例
    private func duplicateProvider(_ p: PluginProvider) {
        EditPanelController.shared.show(EditForm(copy: p, hudDir: hudDir, userDir: userDir, bundleDir: bundleDir, engine: engine))
    }

    /// 触发额度刷新: 发一次 chat 请求触发滚动窗口计算, 成功后立即查余额更新 (反馈行内就近显示)
    private func triggerRefresh(_ p: PluginProvider) {
        guard let authFile = EditForm.authURL(for: p, hudDir: hudDir) else {
            refreshResult = "未找到凭证文件"; refreshResultOK = false; refreshResultSlug = p.slug; return
        }
        refreshingSlug = p.slug
        refreshResult = nil
        refreshResultSlug = nil
        Task {
            let err = await RefreshTrigger.trigger(manifest: p.manifest, authFile: authFile)
            await MainActor.run {
                refreshingSlug = nil
                refreshResultSlug = p.slug
                refreshResultOK = (err == nil)
                if let err {
                    refreshResult = err
                } else {
                    refreshResult = "✓ 已刷新"
                    engine.reloadRegistry()
                    Task { await engine.forceRefresh(slug: p.slug) }
                }
            }
        }
    }

    private func moveTo(_ dragged: String, _ target: String) {
        var order = engine.providerOrder
        if order.isEmpty { order = allProviders.map(\.slug) }
        guard let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(dragged, at: to)
        engine.setProviderOrder(order)
    }

    /// 全部供应商 (含关闭跟踪的), 读 engine 缓存按用户顺序排列 (免渲染期磁盘扫描)
    private var allProviders: [PluginProvider] {
        let order = engine.providerOrder
        return engine.allPlugins.sorted { a, b in
            let ai = order.firstIndex(of: a.slug) ?? order.count
            let bi = order.firstIndex(of: b.slug) ?? order.count
            if ai != bi { return ai < bi }
            return a.slug < b.slug
        }
    }

    private func delete(_ slug: String) {
        // 缺省模板实例删除记 tombstone, 防止迁移复活
        if let p = engine.allPlugins.first(where: { $0.slug == slug }), p.manifest.template != nil {
            engine.markTemplateDeleted(slug)
        }
        try? PluginGenerator.removePlugin(slug: slug, in: userDir)
        engine.reloadRegistry()
        syncHUD()  // 立即同步: 从 envs.json / ACCOUNT_ENVS 移除幽灵条目
    }

    private func syncHUD() {
        do {
            // 脚本分发: statusline + provider .mjs 从 bundle 同步到 hudDir (按钮即"写入完整能力")
            engine.installScripts()
            let plugins = engine.allPlugins
            let builtinNames = Set(plugins.filter { $0.manifest.template != nil }.map { $0.manifest.name })
            let new = HUDSync.envsDict(plugins: plugins, hudDir: hudDir, builtinNames: builtinNames)
            let envsURL = hudDir.appendingPathComponent("envs.json")
            let existing = (try? Data(contentsOf: envsURL))
                .flatMap { try? JSONDecoder().decode([String: EnvsEntry].self, from: $0) } ?? [:]
            try HUDSync.writeEnvs(HUDSync.mergeEnvs(existing: existing, new: new, builtinNames: builtinNames), to: envsURL)
            let keys = plugins
                .filter { $0.manifest.isEnabled && !engine.disabledSlugs.contains($0.slug) }
                .map(\.manifest.name)
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
            let current = (settings?["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String
            try HUDSync.patchSettings(settingsURL: settingsURL,
                accountEnvs: HUDSync.mergeAccountEnvs(current: current, keys: keys),
                statuslinePath: hudDir.appendingPathComponent("statusline.mjs").path)
            syncResult = "✓ 已写入 (statusline 下次渲染生效)"
        } catch {
            syncResult = "✗ \(error.localizedDescription)"
        }
    }

    private func pickNode() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        // 不设 allowedContentTypes: node 无扩展名, 任何 UTType 过滤都会置灰; 默认不限可选到任意文件
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: DataEngine.defaultsNodeKey)
            syncResult = "node 路径已存, 重启 App 生效"
        }
    }
}

/// 拖动排序 drop 代理
struct ProviderDropDelegate: DropDelegate {
    let slug: String
    let all: [String]
    let onMove: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let item = info.itemProviders(for: [.text]).first else { return }
        _ = item.loadObject(ofClass: NSString.self) { obj, _ in
            if let dragged = obj as? String, dragged != slug {
                DispatchQueue.main.async { onMove(dragged, slug) }
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool { true }
}
