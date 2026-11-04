import SwiftUI
import AppKit

struct SettingsCenterView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine
    var renderScript: RenderScript?

    var body: some View {
        Group {
            if let importer = renderScript?.importModel {
                ImportCenterSheet(model: model, engine: engine, im: importer)
            } else {
                NavigationSplitView {
                    AccountSidebar(model: model, engine: engine)
                        .navigationSplitViewColumnWidth(min: 184, ideal: 208, max: 280)
                } detail: {
                    VStack(spacing: 0) {
                        pageHeader
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Palette.canvas)
                }
                .navigationSplitViewStyle(.balanced)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { model.openTemplates() } label: { Label("添加账号", systemImage: "plus") }
                            .keyboardShortcut("n", modifiers: .command)
                        Button { model.openImport() } label: { Label("导入账号", systemImage: "square.and.arrow.down") }
                        if let row = model.current, model.navPage == .detail, model.draft == nil {
                            Button { model.duplicateAccount(row.id) } label: { Label("复制账号", systemImage: "plus.square.on.square") }
                                .keyboardShortcut("d", modifiers: .command)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let toast = model.toast {
                        Label(toast.text, systemImage: toast.isError ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.callout).foregroundStyle(toast.isError ? Color.red : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(.bar)
                            .accessibilityElement(children: .combine)
                    }
                }
                .sheet(isPresented: $model.importOpen) {
                    ImportCenterSheet(model: model, engine: engine, im: model.importer)
                }
            }
        }
        .font(.system(size: 13))
        .tint(Palette.ink)
        .accentColor(Palette.ink)
        .groupBoxStyle(QuietGroupBoxStyle())
        .sheet(item: Binding(get: { model.pendingTestConfirmation }, set: { value in
            if value == nil { model.cancelPendingTestCall() }
        }), onDismiss: { model.cancelPendingTestCall() }) { confirmation in
            CallTestConfirmationSheet(confirmation: confirmation,
                                      onSend: { model.confirmPendingTestCall() },
                                      onCancel: { model.cancelPendingTestCall() })
                .onDisappear { model.cancelPendingTestCall() }
        }
        .onAppear { applyRenderScript() }
        .onExitCommand {
            if model.draft != nil { model.cancelEdit() }
            else if model.showingTemplates { model.closeTemplates() }
        }
    }

    private var pageHeader: some View {
        HStack(spacing: 8) {
            Text("TokenHUD").foregroundStyle(Palette.muted)
            Text("/").foregroundStyle(Palette.muted.opacity(0.6))
            Text(pageName).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20).frame(height: 42)
    }
    private var pageName: String {
        switch model.navPage {
        case .overview: return "账号 / 概览"
        case .plan: return "调用计划"
        case .settings: return "设置与外观"
        case .detail:
            if model.showingTemplates { return "添加账号" }
            if model.draft?.isNew == true { return "新建账号" }
            return model.current?.name ?? "账号"
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.navPage {
        case .settings: GlobalSettingsPage(model: model, engine: engine)
        case .plan: PlanPage(model: model)
        case .overview: OverviewPage(model: model, engine: engine)
        case .detail:
            if model.showingTemplates {
                ScrollView { TemplateCatalogView(model: model).padding(20) }
                    .navigationTitle("添加账号")
                    .toolbar { Button("取消") { model.closeTemplates() } }
            } else {
                AccountDetailView(model: model, engine: engine)
            }
        }
    }

    private func applyRenderScript() {
        guard let script = renderScript else { return }
        if let slug = script.slug { _ = model.selectAccount(slug) }
        switch script.mode {
        case .quota: model.tab = .quota; model.navPage = .detail
        case .config: model.tab = .config; model.navPage = .detail
        case .trigger: model.tab = .trigger; model.navPage = .detail
        case .edit: model.tab = .config; model.navPage = .detail; model.startEdit()
        case .editTrigger: model.tab = .trigger; model.navPage = .detail; model.startEdit()
        case .templates: model.openTemplates()
        case .create:
            model.openTemplates()
            if let choice = model.choices.first(where: { $0.id == script.templateID }) { model.pickTemplate(choice) }
        case .importer: model.importOpen = true
        case .plan: model.navPage = .plan
        case .globalSettings: model.navPage = .settings
        case .full, .overview: break
        }
    }
}

private struct AccountSidebar: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine
    @State private var hovered: String?
    @FocusState private var focusedRow: String?

    private var selected: String? {
        if model.showingTemplates || model.draft?.isNew == true { return nil }
        switch model.navPage {
        case .overview: return "page:accounts"
        case .plan: return "page:plan"
        case .settings: return "page:settings"
        case .detail: return model.selected
        }
    }
    private func choose(_ id: String) {
        switch id {
        case "page:accounts": model.navigate(to: .overview)
        case "page:plan": model.navigate(to: .plan)
        case "page:settings": model.navigate(to: .settings)
        default: _ = model.selectAccount(id, tab: .config)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    navRow("全部账号", icon: "person.2", id: "page:accounts")
                    navRow("调用计划", icon: "calendar.badge.clock", id: "page:plan")
                    HStack {
                        Text("账号列表").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Spacer(minLength: 2)
                        Picker("账号列表状态", selection: $model.sidebarStatusFilter) {
                            ForEach(AccountStatusFilter.allCases) { filter in Text(filter.label).tag(filter) }
                        }.labelsHidden().pickerStyle(.menu)
                            .accessibilityIdentifier("sidebar.status-filter")
                    }.padding(.horizontal, 8).padding(.top, 12)
                    if model.sidebarGroups.isEmpty {
                        Text("没有符合条件的账号")
                            .font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    ForEach(model.sidebarGroups, id: \.label) { group in
                        Text(group.fullName).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.muted).padding(.horizontal, 10).padding(.top, 17).padding(.bottom, 3)
                        ForEach(group.rows) { row in
                            navRow(row.name, icon: row.plugin.manifest.icon ?? "network", id: row.id, disabled: !row.enabled)
                                .contextMenu { AccountContextMenu(model: model, row: row) }
                        }
                    }
                }.padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 12)
            }
            navRow("设置与外观", icon: "gearshape", id: "page:settings")
                .padding(10)
        }
        .background(Palette.canvas)
        .searchable(text: $model.search, prompt: "搜索账号或供应商")
        .navigationTitle("TokenHUD")
        .onMoveCommand { direction in
            let ids = ["page:accounts", "page:plan"] + model.sidebarGroups.flatMap { $0.rows.map(\.id) } + ["page:settings"]
            guard let current = (focusedRow ?? selected).flatMap({ ids.firstIndex(of: $0) }) else { return }
            let next = direction == .down ? current + 1 : (direction == .up ? current - 1 : current)
            guard ids.indices.contains(next), next != current else { return }
            choose(ids[next])
            if selected == ids[next] { focusedRow = ids[next] }
        }
    }
    private func navRow(_ text: String, icon: String, id: String, disabled: Bool = false) -> some View {
        Button { choose(id) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 17)
                    .foregroundStyle(selected == id ? Palette.ink : Palette.controlText)
                Text(text).font(.system(size: 13, weight: selected == id ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if disabled { StatusDot(color: Palette.muted) }
            }
            .foregroundStyle(Palette.ink).padding(.horizontal, 10).frame(height: 32)
            .background(selected == id ? Palette.surface : (hovered == id ? Palette.hover.opacity(0.5) : .clear),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected == id ? Palette.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedRow, equals: id)
        .accessibilityLabel(text).accessibilityIdentifier("sidebar." + id)
        .accessibilityValue(selected == id ? "已选择" : "")
        .onHover { hovered = $0 ? id : nil }
    }
}

struct OverviewPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine
    @State private var dropTarget: String?
    private func moveProviderCard(_ source: String, to target: String) -> Bool {
        var labels: [String] = []
        var accounts: [String: [String]] = [:]
        for provider in engine.allPlugins {
            let type = provider.manifest.template.flatMap { engine.template(bySlug: $0)?.manifest }
                ?? provider.manifest
            if accounts[type.label] == nil { labels.append(type.label) }
            accounts[type.label, default: []].append(provider.slug)
        }
        guard let from = labels.firstIndex(of: source), let to = labels.firstIndex(of: target) else { return false }
        if from != to {
            let moved = labels.remove(at: from)
            labels.insert(moved, at: to)
            withAnimation(.easeInOut(duration: 0.18)) {
                engine.setProviderOrder(labels.flatMap { accounts[$0] ?? [] })
            }
        }
        dropTarget = nil
        return true
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("额度与账号").foregroundStyle(Palette.muted)
                    Text("拖动卡片调整顺序").font(Typo.small).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("查询全部额度", systemImage: "arrow.clockwise") {
                        for row in model.allAccounts where row.enabled && row.canQuery && model.quotaConfigured(row) {
                            model.query(row.id)
                        }
                    }
                    .barButton()
                    .disabled(!model.allAccounts.contains { $0.enabled && $0.canQuery && model.quotaConfigured($0) })
                }
                HStack(spacing: 12) {
                    Picker("账号状态", selection: $model.overviewStatusFilter) {
                        ForEach(AccountStatusFilter.allCases) { filter in Text(filter.label).tag(filter) }
                    }.pickerStyle(.segmented).frame(maxWidth: 560)
                        .accessibilityIdentifier("overview.status-filter")
                    Text("\(model.overviewGroups.reduce(0) { $0 + $1.rows.count }) 个账号")
                        .font(Typo.small).foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                }
                if model.overviewGroups.isEmpty {
                    ContentUnavailableView(model.allAccounts.isEmpty ? "尚无账号" : "没有符合条件的账号",
                                           systemImage: "person.crop.circle.badge.plus",
                                           description: Text(model.allAccounts.isEmpty ? "添加一个账号开始使用。" : "调整状态过滤或搜索条件。"))
                }
                LazyVGrid(columns: model.overviewGroups.count == 1 ? [GridItem(.flexible(), alignment: .top)] : [GridItem(.adaptive(minimum: 290), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                    ForEach(model.overviewGroups, id: \.label) { group in
                        CardBox(onDoubleClick: {
                            if let row = group.rows.first { _ = model.selectAccount(row.id, tab: .config) }
                        }) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 7) {
                                    Image(systemName: group.rows.first?.plugin.manifest.icon ?? "network")
                                        .foregroundStyle(Palette.accent).frame(width: 17)
                                    Text(group.fullName).font(.system(size: 13, weight: .semibold))
                                    Spacer(minLength: 0)
                                    Text("\(group.rows.count) 个账号").font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    if let row = group.rows.first { _ = model.selectAccount(row.id, tab: .config) }
                                }
                                .help("双击打开账号详情")
                                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { Divider().overlay(Palette.border) }
                                    OverviewAccountCard(model: model, row: row)
                                }
                            }
                        }
                        .draggable("tokenhud-provider-card:" + group.label)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("provider-card." + group.label)
                        .dropDestination(for: String.self) { items, _ in
                            guard let payload = items.first, payload.hasPrefix("tokenhud-provider-card:") else { return false }
                            return moveProviderCard(String(payload.dropFirst("tokenhud-provider-card:".count)), to: group.label)
                        } isTargeted: { targeted in
                            if targeted { dropTarget = group.label }
                            else if dropTarget == group.label { dropTarget = nil }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(dropTarget == group.label ? Palette.accent : .clear, lineWidth: 2)
                            .allowsHitTesting(false))

                    }
                }
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.bottom, 20)
        }
    }
}

private struct OverviewAccountCard: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow
    private var quota: QuotaPresentation { QuotaPresentation(state: row.state) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { _ = model.selectAccount(row.id, tab: .config) } label: {
                    Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }.buttonStyle(.plain)
                Spacer(minLength: 0)
                Toggle("启用", isOn: Binding(get: { row.enabled }, set: { model.toggleMonitoring(row.id, enabled: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("启用 \(row.name)")
                Menu { AccountContextMenu(model: model, row: row) } label: {
                    Image(systemName: "ellipsis").frame(width: 20, height: 20)
                }.menuStyle(.borderlessButton).fixedSize().help("账号操作")
            }
            if row.canQuery && !quota.metrics.isEmpty {
                QuotaMetricGrid(metrics: quota.metrics, old: quota.isOld || !row.enabled, compact: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(status).foregroundStyle(!row.health.isHealthy ? Palette.danger : (quota.isOld ? Palette.warn : Palette.muted))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if row.canQuery {
                    Button { model.query(row.id) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("查询额度")
                        .disabled(!model.quotaConfigured(row) || model.running.contains(row.id))
                }
            }.font(.system(size: 11))
            if row.canQuery && !quota.metrics.isEmpty {
                Text("更新于 \(quota.updated)").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { _ = model.selectAccount(row.id, tab: .config) }
        .help("双击打开账号详情")
        .contextMenu { AccountContextMenu(model: model, row: row) }
    }
    private var status: String {
        if !row.enabled {
            return row.health.issueReason.map { "已停用 · 账号异常：" + $0 } ?? "已停用 · 配置和计划保留"
        }
        if let issue = row.health.issueReason { return "账号异常 · " + issue }
        if model.running.contains(row.id) { return "正在查询额度…" }
        if !row.canQuery { return model.callConfigured(row) ? "API 已配置 · 无额度查询" : "API 待配置 · 无额度查询" }
        if !model.quotaConfigured(row) { return "额度查询待配置" }
        return quota.status
    }
}

struct AccountContextMenu: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow
    var body: some View {
        Button("打开账号") { _ = model.selectAccount(row.id, tab: .config) }
        Button("复制账号…") { model.duplicateAccount(row.id) }
        Button("查询额度") { model.query(row.id) }
            .disabled(!row.canQuery || !model.quotaConfigured(row) || model.running.contains(row.id))
        Divider()
        Button(row.enabled ? "停用账号" : "启用账号") { model.toggleMonitoring(row.id, enabled: !row.enabled) }
        Button("删除账号…", role: .destructive) { model.delete(row.id) }
    }
}

struct RenderScript {
    enum Mode { case quota, config, trigger, edit, editTrigger, templates, create, importer, full, overview, plan, globalSettings }
    var mode: Mode
    var slug: String?
    var templateID: String?
    var importModel: ImportCenterModel? = nil
}
