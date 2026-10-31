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
                        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
                } detail: {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onAppear { applyRenderScript() }
        .onExitCommand {
            if model.draft != nil { model.cancelEdit() }
            else if model.showingTemplates { model.closeTemplates() }
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
    private var selection: Binding<String?> {
        Binding(get: {
            if model.showingTemplates || model.draft?.isNew == true { return nil }
            if model.navPage == .settings { return "page:settings" }
            if model.navPage == .plan { return "page:plan" }
            if model.navPage == .overview { return "page:accounts" }
            return model.selected
        }, set: { value in
            switch value {
            case "page:settings": model.navigate(to: .settings)
            case "page:plan": model.navigate(to: .plan)
            case "page:accounts": model.navigate(to: .overview)
            case .some(let id): _ = model.selectAccount(id, tab: .config)
            case .none: break
            }
        })
    }
    var body: some View {
        List(selection: selection) {
            Label("全部账号", systemImage: "person.2").tag("page:accounts")
            Label("调用计划", systemImage: "calendar.badge.clock").tag("page:plan")
            ForEach(model.overviewGroups, id: \.label) { group in
                Section(group.fullName) {
                    ForEach(group.rows) { row in
                        HStack(spacing: 8) {
                            ProviderBadge(icon: row.plugin.manifest.icon, label: row.name,
                                          accent: brandColor(row.plugin.manifest.accent), size: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.name).lineLimit(2)
                                Text(row.enabled ? accountSummary(row) : "已停用")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(row.id)
                        .contextMenu { AccountContextMenu(model: model, row: row) }
                    }
                }
            }
            Section {
                Label("设置与外观", systemImage: "gearshape").tag("page:settings")
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.search, prompt: "搜索账号或供应商")
        .navigationTitle("TokenHUD")
    }
    private func accountSummary(_ row: AccountRow) -> String {
        let call = model.callConfigured(row) ? "API 已配置" : "API 未配置"
        return row.canQuery ? call + " · 可查额度" : call + " · 无额度查询"
    }
}

struct OverviewPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine
    var body: some View {
        List {
            Section {
                Text("添加同一供应商的多个账号，分别管理 API 连接、额度查询与调用计划。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("添加账号", systemImage: "plus") { model.openTemplates() }
                    Button("导入账号…", systemImage: "square.and.arrow.down") { model.openImport() }
                    Spacer()
                    Button("查询全部额度", systemImage: "arrow.clockwise") {
                        for row in model.allAccounts where row.enabled && row.canQuery && model.quotaConfigured(row) {
                            model.query(row.id)
                        }
                    }
                    .disabled(!model.allAccounts.contains { $0.enabled && $0.canQuery && model.quotaConfigured($0) })
                }
            }
            if model.accounts.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? "尚无账号" : "没有匹配的账号",
                                       systemImage: "person.crop.circle.badge.plus",
                                       description: Text(model.search.isEmpty ? "添加一个账号开始使用。" : "试试其他名称。"))
            }
            ForEach(model.overviewGroups, id: \.label) { group in
                Section(group.fullName) {
                    ForEach(group.rows) { row in
                        HStack(spacing: 12) {
                            Button { _ = model.selectAccount(row.id, tab: .config) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.name).font(.headline)
                                    Text(accountState(row)).font(.callout).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Toggle("启用", isOn: Binding(get: { row.enabled }, set: { model.toggleMonitoring(row.id, enabled: $0) }))
                                .toggleStyle(.switch).fixedSize()
                                .accessibilityLabel("启用 \(row.name)")
                            Menu { AccountContextMenu(model: model, row: row) } label: {
                                Label("更多操作", systemImage: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton).labelsHidden().fixedSize()
                        }
                        .padding(.vertical, 6)
                        .contextMenu { AccountContextMenu(model: model, row: row) }
                    }
                }
            }
        }
        .navigationTitle("账号管理")
    }
    private func accountState(_ row: AccountRow) -> String {
        if !row.enabled { return "已停用 · 配置和计划保留" }
        let call = model.callConfigured(row) ? "API 可调用" : "API 待配置"
        return call + (row.canQuery ? " · " + QuotaPresentation(state: row.state).status : " · 未启用额度查询")
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
