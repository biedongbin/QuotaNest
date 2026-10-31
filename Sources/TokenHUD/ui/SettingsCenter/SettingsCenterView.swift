import SwiftUI
import AppKit

// MARK: - v0.2 总览仪表盘: 左栏导航 (额度总览/调用计划/设置) + 右侧总览/详情 (AIUsage 式分组卡)

struct SettingsCenterView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine
    /// 离屏渲染钩子: 强制 tab / 面板 / 草稿态 (nil = 正常交互)
    var renderScript: RenderScript?

    var body: some View {
        Group {
            if let im = renderScript?.importModel {
                // 离屏渲染: sheet 不会在离屏窗口弹出, 直接内联同一视图
                ImportCenterSheet(model: model, engine: engine, im: im)
            } else {
                mainBody
            }
        }
        .onAppear { applyRenderScript() }
    }

    private var mainBody: some View {
        HStack(spacing: 0) {
            NavColumn(model: model, engine: engine)
                .frame(width: 184)
            Divider().overlay(Palette.border)
            VStack(spacing: 0) {
                switch model.navPage {
                case .overview:
                    OverviewPage(model: model, engine: engine)
                case .plan:
                    PlanPage(model: model)
                case .settings:
                    GlobalSettingsPage(model: model, engine: engine)
                case .detail:
                    DetailHeader(model: model)
                    Rectangle().fill(Palette.border).frame(height: 1)
                    DetailPanel(model: model, engine: engine)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.canvas)
                }
            }
        }
        .background(Palette.canvas)
        .overlay(alignment: .bottom) { toastBar }
        .sheet(isPresented: $model.importOpen) {
            ImportCenterSheet(model: model, engine: engine, im: model.importer)
        }
        .background {
            // Esc: 草稿 → 取消 (带确认); 模板目录 → 返回账号; 详情 → 返回总览
            Button("") {
                if model.draft != nil { model.cancelEdit() }
                else if model.showingTemplates { model.closeTemplates() }
                else if model.navPage == .detail { model.navigate(to: .overview) }
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private func applyRenderScript() {
        guard let s = renderScript else { return }
        if let slug = s.slug, engine.allPlugins.contains(where: { $0.slug == slug }) {
            model.selected = slug
        }
        switch s.mode {
        case .quota: model.tab = .quota; model.navPage = model.selected != nil ? .detail : .overview
        case .config: model.tab = .config; model.navPage = .detail
        case .trigger: model.tab = .trigger; model.navPage = .detail
        case .edit:
            model.tab = .config
            model.navPage = .detail
            model.startEdit()
        case .editTrigger:
            model.tab = .trigger
            model.navPage = .detail
            model.startEdit()
        case .templates:
            model.openTemplates()
        case .create:
            model.openTemplates()
            if let c = model.choices.first(where: { $0.id == s.templateID }) {
                model.pickTemplate(c)
            }
        case .importer:
            model.importOpen = true
            if let im = renderScript?.importModel { im.scanSynchronously() }
        case .plan:
            model.navPage = .plan
        case .globalSettings:
            model.navPage = .settings
        case .full, .overview:
            break
        }
    }

    @ViewBuilder
    private var toastBar: some View {
        if let toast = model.toast {
            Text(toast.text)
                .font(Typo.body)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(toast.isError ? Palette.danger : Palette.ink))
                .padding(.bottom, 20)
                .transition(.opacity)
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

// MARK: - 左栏导航 (v0.2: 总览/调用计划/全局设置 三段路由)

struct NavColumn: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TokenHUD").font(Typo.section).foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            VStack(spacing: 2) {
                navRow("额度总览", icon: "square.grid.2x2", active: model.navPage == .overview) {
                    model.navigate(to: .overview)
                }
                navRow("调用计划", icon: "clock.arrow.circlepath", active: model.navPage == .plan) {
                    model.navigate(to: .plan)
                }
                navRow("设置", icon: "slider.horizontal.3", active: model.navPage == .settings) {
                    model.navigate(to: .settings)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            Rectangle().fill(Palette.border).frame(height: 1)

            VStack(spacing: 8) {
                Button {
                    model.openTemplates()
                } label: {
                    Label("添加账号", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .barButton()
                .help("添加供应商账号")

                Button {
                    model.openImport()
                } label: {
                    Label("导入账号…", systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                }
                .barButton()
                .help("从本机配置导入账号")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(Palette.sidebar)
    }

    private func navRow(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13))
                Text(title).font(Typo.body)
                Spacer()
            }
            .foregroundStyle(active ? Palette.ink : Palette.muted)
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Palette.surface : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(active ? Palette.border : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 总览页 (AIUsage provider-monitoring 式: 搜索 + 筛选 + 供应商分组 + 账号卡网格)

struct OverviewPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine

    var body: some View {
        VStack(spacing: 0) {
            overviewHeader.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.overviewGroups.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.overviewGroups, id: \.label) { g in
                            providerGroup(g)
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(Palette.canvas)
    }

    // MARK: 头部: 标题 + 搜索 + 筛选分段

    private var overviewHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("额度总览").font(Typo.title).foregroundStyle(Palette.ink)
                Text("\(engine.allPlugins.count) 个账号").font(Typo.small).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Button("查询全部") {
                    for account in model.allAccounts where account.enabled && account.canQuery {
                        model.query(account.id)
                    }
                }
                .barButton()
                .disabled(model.allAccounts.allSatisfy { !$0.enabled || !$0.canQuery })
                .help("查询所有已启用账号的额度")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    searchField
                    scopeFilters
                }
                VStack(alignment: .leading, spacing: 10) {
                    searchField
                    scopeFilters
                }
            }
        }
    }

    private var scopeFilters: some View {
        HStack(spacing: 8) {
            ForEach(SettingsModel.ScopeFilter.allCases) { filter in
                Button { model.scope = filter } label: {
                    Text(filter.label)
                        .font(Typo.small)
                        .foregroundStyle(model.scope == filter ? Palette.accent : Palette.muted)
                        .frame(width: 72, height: 30)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(model.scope == filter ? Palette.accentSoft : Palette.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(model.scope == filter ? Palette.accent : Palette.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("筛选\(filter.label)")
                .accessibilityValue(model.scope == filter ? "已选中" : "未选中")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            TextField("搜索账号或供应商", text: $model.search)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.ink)
            if !model.search.isEmpty {
                Button { model.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 280, height: 32)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(model.search.isEmpty && model.scope == .all ? "尚无账号" : "没有匹配的账号")
                .font(Typo.section).foregroundStyle(Palette.ink)
            Text(model.search.isEmpty && model.scope == .all
                 ? "点左下「添加账号」或「导入账号…」开始。"
                 : "当前搜索或筛选条件下没有账号。")
                .font(Typo.small).foregroundStyle(Palette.muted)
            if !model.search.isEmpty || model.scope != .all {
                Button("清除搜索与筛选") { model.search = ""; model.scope = .all }.barButton()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: 供应商分组: 组头 (徽标+名+计数+刷新+添加) + 账号卡网格

    private func providerGroup(_ g: (label: String, fullName: String, accent: String?, icon: String?,
                                  rows: [AccountRow])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderBadge(icon: g.icon, label: g.label, accent: brandColor(g.accent), size: 24)
                Text(g.fullName).font(Typo.section).foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("\(g.rows.count) 个账号").font(Typo.small).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Button {
                    model.openTemplates()
                } label: {
                    Label("添加账号", systemImage: "plus")
                }
                .barButton(.ghost)
            }
            VStack(spacing: 12) {
                ForEach(g.rows) { row in
                    AccountCard(model: model, row: row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 账号卡 (AIUsage 式: 卡头徽章状态+菜单 / 卡体窗口行 / 卡脚时间+查询)

struct AccountCard: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow

    private var rows: [(label: String, pct: Double?, amount: Double?, limit: Double?,
                        unit: String?, period: String?, resetsAt: Int?)] {
        QuotaTabView.rows(from: row.state?.cache)
    }
    private var isOldValue: Bool { !row.enabled || row.state?.cache?.stale == true || row.state?.cache?.error != nil }
    @State private var hoveringDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .topTrailing) {
                Button(action: openDetail) {
                    VStack(alignment: .leading, spacing: 16) {
                        accountIdentity.padding(.trailing, 148)
                        cardBody
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(hoveringDetails ? Palette.accentSoft : Color.clear))
                }
                .buttonStyle(.plain)
                .help("查看 \(row.name) 的额度详情")
                .accessibilityLabel("查看 \(row.name) 的额度详情")
                .onHover { hoveringDetails = $0 }
                accountControls.padding(16)
            }
            Divider().overlay(Palette.border)
            displayPreferences.padding(.horizontal, 16)
            cardFooter.padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .contextMenu {
            Button("打开额度详情") { openDetail() }
            Button("查询额度") { model.query(row.id) }.disabled(!row.canQuery || !row.isConfigured || model.running.contains(row.id))
            Button("编辑配置") { openConfig() }
            Divider()
            Button(row.enabled ? "停用账号" : "启用账号") { model.toggleMonitoring(row.id, enabled: !row.enabled) }
            Divider()
            Button("删除账号…", role: .destructive) { model.delete(row.id) }
        }
    }

    private func openDetail() { _ = model.selectAccount(row.id, tab: .quota) }
    private func openConfig() { _ = model.selectAccount(row.id, tab: .config) }

    private var accountIdentity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.name).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                BadgeText(text: row.authLabel)
                let (color, word) = row.status
                StatusDot(color: color)
                Text(word).font(Typo.small).foregroundStyle(color)
            }
        }
    }

    private var accountControls: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Toggle("启用账号", isOn: monitorBinding)
                .toggleStyle(.switch).fixedSize()
                .help("停用后暂停该账号的后台查询与定时调用，保留配置")
                .accessibilityLabel("启用 \(row.name)")
            Menu {
                Button("删除账号…", role: .destructive) { model.delete(row.id) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("\(row.name) 的更多操作")
        }
    }

    private var monitorBinding: Binding<Bool> {
        Binding(get: { row.enabled }, set: { model.toggleMonitoring(row.id, enabled: $0) })
    }
    private var floatingBinding: Binding<Bool> {
        Binding(get: { !model.engine.floatingHiddenSlugs.contains(row.id) },
                set: { model.toggleFloating(row.id, shown: $0) })
    }
    private var hudBinding: Binding<Bool> {
        Binding(get: { !model.engine.hudHiddenSlugs.contains(row.id) },
                set: { model.toggleHudSync(row.id, synced: $0) })
    }

    private var displayPreferences: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { preferenceToggles }
            VStack(alignment: .leading, spacing: 10) { preferenceToggles }
        }
        .font(Typo.small)
    }

    @ViewBuilder private var preferenceToggles: some View {
        Toggle("悬浮窗与菜单栏", isOn: floatingBinding).toggleStyle(.checkbox)
        Toggle("Claude Code HUD", isOn: hudBinding).toggleStyle(.checkbox)
    }

    @ViewBuilder private var cardBody: some View {
        if !row.enabled {
            VStack(alignment: .leading, spacing: 12) {
                emptyMessage("账号已停用", detail: "后台查询与定时调用已暂停；仍可手动查询，不会启用后台任务。")
                if !rows.isEmpty {
                    Text("上次查询数据").font(Typo.small).foregroundStyle(Palette.muted)
                    EqualWidthWindowLayout {
                        ForEach(rows.indices, id: \.self) { index in windowRow(rows[index]) }
                    }
                }
            }
        } else if !row.isConfigured {
            emptyMessage("需要完成配置", detail: "补全凭证或地址后，即可查询额度。")
        } else if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if let error = row.state?.cache?.error {
                    Text("查询失败：\(QuotaErrorPresentation.message(for: error))；以下为上次数据。")
                        .font(Typo.small).foregroundStyle(Palette.danger)
                } else if isOldValue {
                    Text("以下为旧值，查询成功后更新。")
                        .font(Typo.small).foregroundStyle(Palette.muted)
                }
                EqualWidthWindowLayout {
                    ForEach(rows.indices, id: \.self) { index in windowRow(rows[index]) }
                }
            }
        } else if let error = row.state?.cache?.error {
            emptyMessage("查询失败", detail: "\(QuotaErrorPresentation.message(for: error))。请检查配置后重试。")
        } else {
            emptyMessage("尚未查询", detail: "查询成功后显示服务实际返回的额度窗口。")
        }
    }

    private func emptyMessage(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Typo.body).foregroundStyle(Palette.ink)
            Text(detail).font(Typo.small).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func windowRow(_ value: (label: String, pct: Double?, amount: Double?, limit: Double?,
                                    unit: String?, period: String?, resetsAt: Int?)) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value.label).font(Typo.small).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Text(value.pct.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(isOldValue ? Palette.muted : pctColor(value.pct))
            }
            if !isOldValue { ProgressLine(pct: value.pct) }
            if let amount = value.amount, let limit = value.limit {
                Text(QuotaTabView.unitLabel(amount, limit, unit: value.unit))
                    .font(Typo.small).foregroundStyle(Palette.muted)
            }
            if isOldValue {
                Text("旧值").font(Typo.small).foregroundStyle(Palette.muted)
            } else if let countdown = HUDFmt.resetCountdown(value.resetsAt, now: Date()) {
                Text("\(countdown) 后重置").font(Typo.small).foregroundStyle(Palette.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.readonlyField))
    }

    private func pctColor(_ value: Double?) -> Color {
        guard let value else { return Palette.muted }
        return value >= 90 ? Palette.danger : (value >= 70 ? Palette.warn : Palette.ok)
    }

    private var cardFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                updateLabel
                Spacer(minLength: 4)
                accountActions
            }
            VStack(alignment: .leading, spacing: 10) {
                updateLabel
                accountActions
            }
        }
    }

    private var updateLabel: some View {
        Text(model.running.contains(row.id) ? "查询中…" : "更新于 \(formatCacheTime(row.state?.cache?.generatedAt))")
            .font(Typo.small).foregroundStyle(Palette.muted)
    }

    private var accountActions: some View {
        HStack(spacing: 8) {
            Button("配置") { openConfig() }.barButton()
            Button(model.running.contains(row.id) ? "查询中…" : "查询额度") { model.query(row.id) }
                .barButton(.primary)
                .disabled(model.running.contains(row.id) || !row.canQuery || !row.isConfigured)
                .help(!row.isConfigured ? "请先完成账号配置" : (!row.enabled ? "账号已停用，手动查询不会启用后台任务" : "查询该账号的额度"))
        }
    }
}

// MARK: - 右栏详情头部 (进入账号详情后显示, 带「返回总览」)

struct DetailHeader: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    model.navigate(to: .overview)
                } label: {
                    Label("返回总览", systemImage: "chevron.left")
                }
                .barButton()
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Typo.title).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { identityBadges }
                        VStack(alignment: .leading, spacing: 6) { identityBadges }
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    accountGate
                    Spacer(minLength: 0)
                    actions
                }
                VStack(alignment: .leading, spacing: 10) {
                    accountGate
                    actions
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            if model.showingTemplates {
                EmptyView()
            } else {
                tabsRow.padding(.horizontal, 20).padding(.top, 12)
            }
        }
        .padding(.bottom, 0)
        .background(Palette.surface)
    }

    private var title: String {
        if model.showingTemplates { return "新建账号" }
        if let d = model.draft, d.isNew { return "新建账号" }
        return model.current?.name ?? "—"
    }

    private var badges: [String] {
        if model.showingTemplates { return [] }
        if let d = model.draft, d.isNew {
            let label = model.draftManifest()?.fullName ?? "通用兼容"
            return [label, "模板新建"]
        }
        guard let row = model.current else { return [] }
        let provider = model.providerName(for: row)
        var out = provider == row.name ? [] : [provider]
        out.append(row.authLabel)
        out.append(row.enabled ? "已启用" : "已停用")
        return out
    }

    private var lockedBadges: Set<String> {
        ["模板新建", "授权登录", "已停用"]
    }

    private var identityBadges: some View {
        ForEach(badges, id: \.self) { badge in
            BadgeText(text: badge, locked: lockedBadges.contains(badge))
        }
    }

    @ViewBuilder
    private var accountGate: some View {
        if !model.showingTemplates, model.draft?.isNew != true, let row = model.current {
            Button(row.enabled ? "停用账号" : "启用账号") {
                model.toggleMonitoring(row.id, enabled: !row.enabled)
            }
            .barButton(row.enabled ? .plain : .primary)
            .help(row.enabled ? "暂停后台查询和定时调用，保留全部配置" : "启用此账号；恢复已有模型计划前会确认")
            .accessibilityLabel(row.enabled ? "停用 \(row.name)" : "启用 \(row.name)")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if model.showingTemplates {
            Button("取消") { model.closeTemplates() }
                .barButton()
        } else if let d = model.draft, d.isNew {
            Button("返回模板目录") { model.cancelEdit() }.barButton()
        } else if model.draft != nil {
            EmptyView()
        } else if let row = model.current {
            VStack(alignment: .trailing, spacing: 8) {
                if model.tab == .quota, row.canQuery {
                    Button(model.running.contains(row.id) ? "查询中…" : "查询额度") { model.query(row.id) }
                        .barButton(.primary)
                        .disabled(model.running.contains(row.id) || !row.isConfigured)
                        .help(row.enabled ? "查询该账号额度" : "账号已停用，手动查询不会启用后台任务")
                } else if model.tab == .config {
                    Button("编辑配置") { model.startEdit() }.barButton()
                    if row.canCall {
                        Button(model.callRunning.contains(row.id) ? "测试中…" : "发送测试调用") { model.testCall(row.id) }
                            .barButton(.primary)
                            .disabled(model.callRunning.contains(row.id))
                            .help("使用已保存配置发送一次模型调用")
                    }
                }
            }
        }
    }

    private var visibleTabs: [SettingsModel.Tab] {
        // 新建模式 (模板直入) 只有配置与自动任务
        model.draft?.isNew == true ? [.config, .trigger] : SettingsModel.Tab.allCases
    }

    private var tabsRow: some View {
        HStack(spacing: 4) {
            ForEach(visibleTabs) { t in
                Button {
                    model.tab = t
                } label: {
                    HStack(spacing: 6) {
                        Text(t.label).font(.system(size: 14, weight: model.tab == t ? .semibold : .regular))
                        if model.draft != nil, t != .quota {
                            Circle().fill(Palette.accent).frame(width: 6, height: 6)
                        }
                    }
                    .foregroundStyle(model.tab == t ? Palette.ink : Palette.muted)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                        .fill(model.tab == t ? Palette.canvas : Color.clear))
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                        .strokeBorder(model.tab == t ? Palette.border : Color.clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// MARK: - 右栏内容分发

struct DetailPanel: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.topError.isEmpty {
                        errorBanner
                    }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            // 草稿底栏固定在滚动区外: 配置/自动任务两个 tab 都可见可用 (草稿整体保存)
            if model.draft != nil && !model.showingTemplates {
                draftActionBar
            }
        }
    }

    private var draftActionBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.border).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    draftActionNote
                    Spacer(minLength: 8)
                    draftActionButtons
                }
                VStack(alignment: .leading, spacing: 10) {
                    draftActionNote
                    HStack { Spacer(minLength: 0); draftActionButtons }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Palette.surface)
    }

    private var draftActionNote: some View {
        Text(model.tab == .config && model.draftCanCall()
             ? "测试当前输入，不保存；发送调用会消耗额度。"
             : "修改仅在保存后生效，保存不发起请求。")
            .font(Typo.small).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var draftActionButtons: some View {
        HStack(spacing: 8) {
            if model.tab == .config, model.draftCanCall(), let draft = model.draft {
                Button(model.isTestingCurrentConfig ? "测试中…" : "发送测试调用") {
                    model.testCallDraft(values: draft.values)
                }
                .barButton()
                .disabled(model.isTestingCurrentConfig)
            }
            Button("取消") { model.cancelEdit() }.barButton()
            Button("保存") { model.save() }
                .barButton(.primary)
                .keyboardShortcut("s", modifiers: .command)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var errorBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text("无法保存：").font(Typo.small).bold() + Text(model.topError).font(Typo.small)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.danger)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.dangerSoft))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.danger.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        if model.showingTemplates {
            TemplateCatalogView(model: model)
        } else if let row = model.current {
            // 草稿态: 配置/自动任务 tab 各渲染对应段落; 额度 tab 仍看数据 (草稿不丢)
            if let d = model.draft {
                if d.isNew || model.tab != .quota {
                    DraftFormView(model: model, draft: d,
                                  section: model.tab == .trigger ? .trigger : .config)
                } else {
                    QuotaTabView(model: model, row: row)
                }
            } else {
                switch model.tab {
                case .quota: QuotaTabView(model: model, row: row)
                case .config: ConfigTabView(model: model, row: row)
                case .trigger: TriggerTabView(model: model, row: row)
                }
            }
        } else if let d = model.draft {
            DraftFormView(model: model, draft: d)
        } else {
            Text("左侧选择一个账号。").font(Typo.small).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity).padding(.vertical, 40)
        }
    }
}

// MARK: - 渲染钩子

struct RenderScript {
    enum Mode { case quota, config, trigger, edit, editTrigger, templates, create, importer, full,
                overview, plan, globalSettings }
    var mode: Mode
    var slug: String?
    var templateID: String?
    var importModel: ImportCenterModel? = nil
}

// MARK: - v0.2 调用计划页 (全部账号的定时计划, 独立页面非账号详情)

struct PlanPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("调用计划").font(Typo.title).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(model.planRows.filter(\.enabled).count)/\(model.planRows.count) 启用")
                    .font(Typo.small).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("各账号的模型定时调用计划；点行进入该账号的「自动任务」tab 编辑。到点调用会消耗额度。")
                        .font(Typo.small).foregroundStyle(Palette.muted)
                    if model.planRows.isEmpty {
                        Text("暂无账号。可添加或导入账号后设置调用计划。")
                            .font(Typo.body).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 16)
                    } else {
                        ForEach(model.planRows) { row in
                            planRow(row)
                        }
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .background(Palette.canvas)
    }

    private func planRow(_ r: SettingsModel.PlanRow) -> some View {
        Button {
            model.selectAccount(r.slug, tab: .trigger)
        } label: {
            HStack(spacing: 12) {
                ProviderBadge(icon: r.icon, label: r.name, accent: brandColor(r.accent), size: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(r.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        if !r.canCall {
                            BadgeText(text: "尚未配置调用", locked: true)
                        } else if r.times.isEmpty {
                            Text("未设置时间").font(Typo.small).foregroundStyle(Palette.muted)
                        } else if r.enabled {
                            Text("计划已启用").font(Typo.small).foregroundStyle(Palette.ok)
                        } else if r.pausedByAccount {
                            Text("账号已停用，计划暂停").font(Typo.small).foregroundStyle(Palette.muted)
                        } else {
                            Text("计划已关闭").font(Typo.small).foregroundStyle(Palette.muted)
                        }
                    }
                    if r.canCall {
                        HStack(spacing: 6) {
                            if r.times.isEmpty {
                                Text("未设置时间点").font(Typo.small).foregroundStyle(Palette.muted)
                            } else {
                                ForEach(r.times, id: \.self) { t in
                                    Text(t).font(Typo.small).monospacedDigit()
                                        .foregroundStyle(Palette.ink)
                                        .padding(.horizontal, 8).padding(.vertical, 1)
                                        .background(Capsule().fill(Palette.badgeBg))
                                        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                                }
                            }
                            Spacer(minLength: 0)
                            Text(r.lastOutcome ?? "今日无记录")
                                .font(Typo.small)
                                .foregroundStyle(r.lastOutcome == nil ? Palette.muted : Palette.ink)
                        }
                    } else {
                        Text("当前账号尚未配置模型调用。")
                            .font(Typo.small).foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(r.enabled ? 1 : 0.7)
    }
}

// MARK: - v0.2 全局设置页 (全局项, 非账号配置)

struct GlobalSettingsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(Typo.title).foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hudSyncCard
                    iconCard
                    diagnosticsCard
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .background(Palette.canvas)
    }

    // HUD 同步状态 + 手动重写
    private var hudSyncCard: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Claude Code HUD").font(Typo.section).foregroundStyle(Palette.ink)
                Text("已启用同步的账号：")
                    .font(Typo.small).foregroundStyle(Palette.muted)
                if engine.hudSyncNames.isEmpty {
                    Text("无").font(Typo.small).foregroundStyle(Palette.muted)
                } else {
                    HStack(spacing: 6) {
                        ForEach(engine.hudSyncNames, id: \.self) { n in
                            BadgeText(text: n)
                        }
                    }
                }
                Button("同步到 Claude Code HUD") { model.syncHUD() }.barButton()
                    .help("同步已启用的账号额度到 Claude Code HUD")
            }
        }
    }

    // 菜单栏图标供应商
    private var iconCard: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("菜单栏图标").font(Typo.section).foregroundStyle(Palette.ink)
                Text("图标显示哪家的已用百分比；「全部」取各家最高值。")
                    .font(Typo.small).foregroundStyle(Palette.muted)
                Picker("图标供应商", selection: iconBinding) {
                    Text("全部（取最高）").tag("")
                    ForEach(model.allAccounts.filter(\.enabled)) { r in
                        Text(r.name).tag(r.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private var iconBinding: Binding<String> {
        Binding(get: { engine.iconProviderSlug ?? "" },
                set: { engine.setIconProvider($0.isEmpty ? nil : $0) })
    }

    // 诊断信息 (只展示真实存在的)
    private var diagnosticsCard: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("诊断").font(Typo.section).foregroundStyle(Palette.ink)
                VStack(spacing: 0) {
                    KeyValueRow("版本") {
                        Text(Self.appVersion)
                    }
                    KeyValueRow("node") {
                        if let p = engine.nodePathForUI {
                            Text(p).font(Typo.mono)
                        } else {
                            Text("未找到 — 菜单栏会提示").foregroundStyle(Palette.warn)
                        }
                    }
                    KeyValueRow("HUD 目录") {
                        Text(model.hudDir.path).font(Typo.mono)
                    }
                    KeyValueRow("账号目录") {
                        Text(model.userDir.path).font(Typo.mono)
                    }
                }
            }
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
