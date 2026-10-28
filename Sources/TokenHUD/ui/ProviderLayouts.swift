import SwiftUI

// MARK: - 版本 A: 侧栏 + 详情

struct SplitLayout: View {
    @ObservedObject var engine: DataEngine
    let rows: [ManagerRow]
    @Binding var selected: String?
    let hudDir: URL, userDir: URL
    let bundleDir: URL?
    let onToast: (String) -> Void

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
            detail
                .frame(minWidth: 420)
        }
        .onAppear { if selected == nil { selected = rows.first?.id } }
    }

    private var list: some View {
        List(selection: $selected) {
            ForEach(grouped, id: \.0) { group, items in
                Section(group) {
                    ForEach(items) { r in
                        SidebarRow(row: r).tag(r.id)
                            .contextMenu { RowMenu(engine: engine, row: r, hudDir: hudDir,
                                                   userDir: userDir, bundleDir: bundleDir,
                                                   onToast: onToast) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// 分组: API Key 在前, 本机登录在后 (空组不显示)
    private var grouped: [(String, [ManagerRow])] {
        var out: [(String, [ManagerRow])] = []
        let ak = rows.filter { !$0.isLocal }
        let lo = rows.filter { $0.isLocal }
        if !ak.isEmpty { out.append(("API Key", ak)) }
        if !lo.isEmpty { out.append(("本机登录", lo)) }
        return out
    }

    @ViewBuilder
    private var detail: some View {
        if let r = rows.first(where: { $0.id == selected }) {
            ProviderDetail(row: r, engine: engine, hudDir: hudDir,
                           userDir: userDir, bundleDir: bundleDir, onToast: onToast)
        } else {
            EmptyHint(title: "选择左侧供应商", detail: "或点右上「添加」新建一个")
        }
    }
}

private struct SidebarRow: View {
    let row: ManagerRow
    var body: some View {
        HStack(spacing: 8) {
            ProviderBadge(icon: row.plugin.manifest.icon, label: row.plugin.manifest.label,
                          accent: brandColor(row.plugin.manifest.accent), size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.plugin.manifest.fullName)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(row.status.color).frame(width: 5, height: 5)
                    Text(row.status.text).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let w = row.worst { PctText(pct: w, size: 12, weight: .semibold) }
        }
        .padding(.vertical, 3)
        .opacity(row.enabled ? 1 : 0.5)
    }
}

// MARK: - 版本 B: 卡片网格

struct GridLayout: View {
    @ObservedObject var engine: DataEngine
    let rows: [ManagerRow]
    let hudDir: URL, userDir: URL
    let bundleDir: URL?
    let onToast: (String) -> Void

    private let cols = [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(rows) { r in
                    ProviderCardCell(row: r, engine: engine, hudDir: hudDir, userDir: userDir,
                                     bundleDir: bundleDir, onToast: onToast)
                }
            }
            .padding(14)
        }
    }
}

private struct ProviderCardCell: View {
    let row: ManagerRow
    @ObservedObject var engine: DataEngine
    let hudDir: URL, userDir: URL
    let bundleDir: URL?
    let onToast: (String) -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderBadge(icon: row.plugin.manifest.icon, label: row.plugin.manifest.label,
                              accent: brandColor(row.plugin.manifest.accent), size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.plugin.manifest.fullName)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                    Text(row.isLocal ? "本机登录" : "API Key")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if hover {
                    Menu {
                        RowMenu(engine: engine, row: row, hudDir: hudDir, userDir: userDir,
                                bundleDir: bundleDir, onToast: onToast)
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }

            if row.buckets.isEmpty {
                Text(row.status == .idle ? "无数据" : row.status.text)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(row.buckets, id: \.0) { label, b in
                    HStack(spacing: 6) {
                        Text(label).font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
                        UsageBar(pct: b.usedPercentage).frame(height: 5)
                        PctText(pct: b.usedPercentage, size: 11, weight: .semibold)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            HStack(spacing: 6) {
                Circle().fill(row.status.color).frame(width: 6, height: 6)
                Text(row.status.text).font(.caption2).foregroundStyle(.secondary)
                if let e = row.state?.cache?.error, e != "auth", e != "fetch" {
                    Text(e).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { row.enabled },
                    set: { engine.setTracking(row.id, enabled: $0) }))
                    .labelsHidden().controlSize(.mini)
                    .help(row.enabled ? "关闭跟踪" : "开启跟踪")
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(hover ? 0.08 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
        .opacity(row.enabled ? 1 : 0.55)
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { edit() }
        .contextMenu { RowMenu(engine: engine, row: row, hudDir: hudDir, userDir: userDir,
                               bundleDir: bundleDir, onToast: onToast) }
    }

    private func edit() {
        EditPanelController.shared.show(EditForm(p: row.plugin, hudDir: hudDir, userDir: userDir,
                                                 bundleDir: bundleDir, engine: engine))
    }
}

// MARK: - 版本 C: 高密度清单

struct DenseLayout: View {
    @ObservedObject var engine: DataEngine
    let rows: [ManagerRow]
    let hudDir: URL, userDir: URL
    let bundleDir: URL?
    let onToast: (String) -> Void
    @State private var expanded: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                Divider()
                ForEach(rows) { r in
                    DenseRow(row: r, engine: engine, expanded: expanded == r.id, all: rows.map(\.id),
                             hudDir: hudDir, userDir: userDir, bundleDir: bundleDir, onToast: onToast,
                             onExpand: { expanded = expanded == r.id ? nil : r.id })
                    Divider().opacity(0.5)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Dense.colGap) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            Text("模式").frame(width: Dense.modeW, alignment: .leading)
            Text("5h").frame(width: Dense.bucketW, alignment: .trailing)
            Text("周").frame(width: Dense.bucketW, alignment: .trailing)
            Text("月").frame(width: Dense.bucketW, alignment: .trailing)
            Text("状态").padding(.leading, Dense.statusPad)
                .frame(width: Dense.statusW + Dense.statusPad, alignment: .leading)
            Text("跟踪").frame(width: Dense.toggleW)
        }
        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}

/// 拖动排序 drop 代理 (三版共用)
struct ProviderDropDelegate: DropDelegate {
    let slug: String
    let all: [String]
    let onMove: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let item = info.itemProviders(for: [.text]).first else { return }
        _ = item.loadObject(ofClass: NSString.self) { obj, _ in
            guard let dragged = obj as? String, dragged != slug else { return }
            DispatchQueue.main.async { onMove(dragged, slug) }
        }
    }

    func performDrop(info: DropInfo) -> Bool { true }
}

/// 清单版列宽常量 (表头与数据行共用, 防错位)
enum Dense {
    static let colGap: CGFloat = 8
    static let modeW: CGFloat = 62
    static let bucketW: CGFloat = 84
    static let statusW: CGFloat = 64
    /// 月列与状态列之间额外间隙 (视觉分组)
    static let statusPad: CGFloat = 10
    static let toggleW: CGFloat = 40
}

private struct DenseRow: View {
    let row: ManagerRow
    @ObservedObject var engine: DataEngine
    let expanded: Bool
    let all: [String]
    let hudDir: URL, userDir: URL
    let bundleDir: URL?
    let onToast: (String) -> Void
    let onExpand: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Dense.colGap) {
                HStack(spacing: 7) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .onDrag { NSItemProvider(object: row.id as NSString) }
                        .onDrop(of: [.text], delegate: ProviderDropDelegate(
                            slug: row.id, all: all, onMove: move))
                        .accessibilityLabel("拖动排序")
                    ProviderBadge(icon: row.plugin.manifest.icon, label: row.plugin.manifest.label,
                                  accent: brandColor(row.plugin.manifest.accent), size: 20)
                    Text(row.plugin.manifest.fullName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(row.isLocal ? "本机" : "API Key").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: Dense.modeW, alignment: .leading)

                cell("five_hour")
                cell("seven_day")
                cell("monthly")

                HStack(spacing: 4) {
                    Circle().fill(row.status.color).frame(width: 6, height: 6)
                    Text(row.status.text).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, Dense.statusPad)
                .frame(width: Dense.statusW + Dense.statusPad, alignment: .leading)

                Toggle("", isOn: Binding(get: { row.enabled },
                                         set: { engine.setTracking(row.id, enabled: $0) }))
                    .labelsHidden().controlSize(.mini).frame(width: Dense.toggleW)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(hover ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(count: 2) { edit() }
            .onTapGesture { onExpand() }
            .contextMenu { RowMenu(engine: engine, row: row, hudDir: hudDir, userDir: userDir,
                                   bundleDir: bundleDir, onToast: onToast) }

            if expanded { DenseDetail(row: row, onEdit: edit) }
        }
        .opacity(row.enabled ? 1 : 0.55)
    }

    private func cell(_ key: String) -> some View {
        let b: Bucket? = key == "five_hour" ? row.state?.cache?.fiveHour
            : key == "seven_day" ? row.state?.cache?.sevenDay : row.state?.cache?.monthly
        return HStack(spacing: 4) {
            if let b, let p = b.usedPercentage {
                UsageBar(pct: p).frame(width: 32, height: 4)
                PctText(pct: p, size: 10, weight: .medium)
                    .frame(width: 32, alignment: .trailing) // 定宽防 100% 撑开错列
            } else {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
                    .frame(width: 68, alignment: .trailing)
            }
        }
        .frame(width: Dense.bucketW, alignment: .trailing)
    }

    /// 拖拽排序: 补齐未在顺序表里的 slug, 再按移除后索引偏移插入
    private func move(_ dragged: String, _ target: String) {
        var order = engine.providerOrder
        if order.isEmpty { order = engine.allPlugins.map(\.slug) }
        for s in engine.allPlugins.map(\.slug) where !order.contains(s) { order.append(s) }
        guard let from = order.firstIndex(of: dragged),
              var to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        if from < to { to -= 1 }
        order.insert(dragged, at: to)
        engine.setProviderOrder(order)
    }

    private func edit() {
        EditPanelController.shared.show(EditForm(p: row.plugin, hudDir: hudDir, userDir: userDir,
                                                 bundleDir: bundleDir, engine: engine))
    }
}

private struct DenseDetail: View {
    let row: ManagerRow
    let onEdit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(row.plugin.slug).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(row.plugin.manifest.template ?? "自定义")
                    .font(.caption2).foregroundStyle(.secondary)
                if let u = row.plugin.manifest.queryUrl {
                    Text(u).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Button("编辑…") { onEdit() }.buttonStyle(.borderless).font(.caption)
            }
            ForEach(row.buckets, id: \.0) { label, b in
                HStack(spacing: 6) {
                    Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
                    UsageBar(pct: b.usedPercentage, style: .thick).frame(width: 160, height: 7)
                    PctText(pct: b.usedPercentage, size: 11)
                    if let rt = HUDFmt.resetCountdown(b.resetsAt, now: Date()) {
                        CountdownChip(text: rt)
                    }
                }
            }
        }
        .padding(.leading, 41).padding(.trailing, 14).padding(.bottom, 8)
    }
}

// MARK: - 详情 (版本 A 右栏)

struct ProviderDetail: View {
    let row: ManagerRow
    @ObservedObject var engine: DataEngine
    let hudDir: URL, userDir: URL
    let bundleDir: URL?
    let onToast: (String) -> Void
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                head
                usageCard
                credentialCard
                triggerCard
                footer
            }
            .padding(16)
        }
    }

    private var head: some View {
        HStack(spacing: 12) {
            ProviderBadge(icon: row.plugin.manifest.icon, label: row.plugin.manifest.label,
                          accent: brandColor(row.plugin.manifest.accent), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.plugin.manifest.fullName)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                HStack(spacing: 6) {
                    Text(row.plugin.slug).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    Text(row.isLocal ? "本机登录" : "API Key")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Circle().fill(row.status.color).frame(width: 6, height: 6)
                    Text(row.status.text).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("跟踪", isOn: Binding(get: { row.enabled },
                                        set: { engine.setTracking(row.id, enabled: $0) }))
                .toggleStyle(.switch).controlSize(.small)
        }
    }

    private var usageCard: some View {
        Card("用量") {
            if row.buckets.isEmpty {
                Text("暂无数据 — 点下方「刷新额度」或用「测试」检查配置")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(row.buckets, id: \.0) { label, b in
                    HStack(spacing: 8) {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .leading)
                        UsageBar(pct: b.usedPercentage, style: .thick).frame(height: 8)
                        PctText(pct: b.usedPercentage, size: 14, weight: .bold)
                            .frame(width: 48, alignment: .trailing)
                        if let rt = HUDFmt.resetCountdown(b.resetsAt, now: Date()) {
                            CountdownChip(text: rt)
                        } else {
                            Spacer().frame(width: 1)
                        }
                    }
                }
            }
            if let g = row.state?.cache?.generatedAt {
                Text("更新于 \(FloatingView.time(Date(timeIntervalSince1970: g / 1000)))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var credentialCard: some View {
        Card("凭证") {
            if row.isLocal {
                LabeledContent("来源") {
                    Text(row.plugin.manifest.name == "GPT" ? "~/.codex/auth.json" : "本机 CLI 登录")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text("凭证由本机 CLI 维护, TokenHUD 只读不写回")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                LabeledContent("模式") { Text("API Key").font(.caption) }
                Text("编辑窗内可填写/替换密钥并测试连通")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var triggerCard: some View {
        Card("触发") {
            LabeledContent("协议") {
                Text(row.plugin.manifest.refreshProtocol ?? "—").font(.caption.monospaced())
            }
            LabeledContent("测试模型") {
                Text(row.plugin.manifest.refreshModel.isEmpty ? "未配置" : row.plugin.manifest.refreshModel)
                    .font(.caption.monospaced())
            }
            if let u = row.plugin.manifest.refreshUrl {
                LabeledContent("url") {
                    Text(u).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                refresh()
            } label: {
                if busy { ProgressView().controlSize(.small) }
                else { Label("刷新额度", systemImage: "arrow.clockwise") }
            }
            .disabled(busy)
            Button("编辑…") { edit() }
            Spacer()
            Button("删除", role: .destructive) { delete() }
        }
    }

    private func edit() {
        EditPanelController.shared.show(EditForm(p: row.plugin, hudDir: hudDir, userDir: userDir,
                                                 bundleDir: bundleDir, engine: engine))
    }

    private func refresh() {
        busy = true
        Task {
            await engine.forceRefresh(slug: row.id)
            await MainActor.run { busy = false; onToast("✓ 已刷新 \(row.plugin.manifest.fullName)") }
        }
    }

    private func delete() {
        let alert = NSAlert()
        alert.messageText = "删除 \(row.plugin.manifest.fullName)?"
        alert.informativeText = "将移除插件目录, 不可撤销"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if row.plugin.manifest.template != nil { engine.markTemplateDeleted(row.id) }
        try? PluginGenerator.removePlugin(slug: row.id, in: userDir)
        engine.reloadRegistry()
        onToast("已删除 \(row.plugin.manifest.fullName)")
    }
}

// MARK: - 共用

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct EmptyHint: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(detail).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 右键菜单 (三版共用)
struct RowMenu: View {
    @ObservedObject var engine: DataEngine
    let row: ManagerRow
    let hudDir: URL, userDir: URL
    let bundleDir: URL?
    let onToast: (String) -> Void

    var body: some View {
        Button("编辑…") {
            EditPanelController.shared.show(EditForm(p: row.plugin, hudDir: hudDir, userDir: userDir,
                                                     bundleDir: bundleDir, engine: engine))
        }
        if row.plugin.manifest.authFile != nil {
            Button("复制账号…") {
                EditPanelController.shared.show(EditForm(copy: row.plugin, hudDir: hudDir, userDir: userDir,
                                                         bundleDir: bundleDir, engine: engine))
            }
        }
        Button("刷新额度") {
            Task {
                await engine.forceRefresh(slug: row.id)
                onToast("✓ 已刷新 \(row.plugin.manifest.fullName)")
            }
        }
        Button(row.enabled ? "关闭跟踪" : "开启跟踪") {
            engine.setTracking(row.id, enabled: !row.enabled)
        }
        Divider()
        Button("删除", role: .destructive) {
            if row.plugin.manifest.template != nil { engine.markTemplateDeleted(row.id) }
            try? PluginGenerator.removePlugin(slug: row.id, in: userDir)
            engine.reloadRegistry()
            onToast("已删除 \(row.plugin.manifest.fullName)")
        }
    }
}
