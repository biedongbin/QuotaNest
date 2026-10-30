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
                .frame(width: 200)
            Divider().overlay(Palette.border)
            VStack(spacing: 0) {
                if model.selected != nil || model.showingTemplates || model.draft != nil {
                    DetailHeader(model: model)
                    Rectangle().fill(Palette.border).frame(height: 1)
                    DetailPanel(model: model, engine: engine)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.canvas)
                } else {
                    OverviewPage(model: model, engine: engine)
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
                else if model.showingTemplates { model.showingTemplates = false }
                else if model.selected != nil { model.selectAccount("") ; model.selected = nil }
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
        case .quota: model.tab = .quota
        case .config: model.tab = .config
        case .trigger: model.tab = .trigger
        case .edit:
            model.tab = .config
            model.startEdit()
        case .editTrigger:
            model.tab = .trigger
            model.startEdit()
        case .templates:
            model.showingTemplates = true
        case .create:
            model.showingTemplates = true
            if let c = model.choices.first(where: { $0.id == s.templateID }) {
                model.pickTemplate(c)
            }
        case .importer:
            model.importOpen = true
            if let im = renderScript?.importModel { im.scanSynchronously() }
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

// MARK: - 左栏导航 (v0.2: 账号列表移除, 总览页即账号列表)

struct NavColumn: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine

    private var inDetail: Bool { model.selected != nil || model.showingTemplates || model.draft != nil }

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
                navRow("额度总览", icon: "square.grid.2x2", active: !inDetail) {
                    backToOverview()
                }
                navRow("调用计划", icon: "clock.arrow.circlepath", active: false) { backToOverviewThenTab(.trigger) }
                navRow("设置", icon: "slider.horizontal.3", active: false) { backToOverviewThenTab(.config) }
            }
            .padding(.horizontal, 8)

            Spacer()

            Rectangle().fill(Palette.border).frame(height: 1)

            VStack(spacing: 8) {
                Button {
                    if !inDetail { model.openTemplates() } else { backToOverviewThen(nil) { model.openTemplates() } }
                } label: {
                    Label("添加账号", systemImage: "plus")
                }
                .barButton().frame(maxWidth: .infinity)

                Button {
                    if !inDetail { model.openImport() } else { backToOverviewThen(nil) { model.openImport() } }
                } label: {
                    Label("导入…", systemImage: "square.and.arrow.down.on.square")
                }
                .barButton().frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(Palette.sidebar)
    }

    /// 有草稿先走 guard; 返回总览 (清选中, 不动 tab)
    private func backToOverview() {
        guard model.leaveGuard() else { return }
        model.showingTemplates = false
        model.draft = nil
        model.selected = nil
    }

    /// 返回总览后进指定账号 tab (调用计划/设置: 取第一个账号; 无账号仅返回)
    private func backToOverviewThenTab(_ tab: SettingsModel.Tab) {
        backToOverviewThen(tab) {}
    }

    private func backToOverviewThen(_ tab: SettingsModel.Tab?, then: @escaping () -> Void) {
        guard model.leaveGuard() else { return }
        model.showingTemplates = false
        model.draft = nil
        if let tab, let first = model.accounts.first {
            model.selected = first.id
            model.tab = tab
        } else {
            model.selected = nil
        }
        then()
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

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 10)]

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
            HStack(alignment: .firstTextBaseline) {
                Text("额度总览").font(Typo.title).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(engine.allPlugins.count) 个账号").font(Typo.small).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 8) {
                searchField
                Picker("", selection: $model.scope) {
                    ForEach(SettingsModel.ScopeFilter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
                .labelsHidden()
            }
        }
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
        .frame(height: 30)
        .frame(maxWidth: 320)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(model.search.isEmpty && model.scope == .all ? "尚无账号" : "没有匹配的账号")
                .font(Typo.section).foregroundStyle(Palette.ink)
            Text(model.search.isEmpty && model.scope == .all
                 ? "点左下「添加账号」或「导入…」开始。"
                 : "换个关键词或筛选条件试试。")
                .font(Typo.small).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: 供应商分组: 组头 (徽标+名+计数+刷新+添加) + 账号卡网格

    private func providerGroup(_ g: (label: String, fullName: String, accent: String?, icon: String?,
                                  rows: [AccountRow])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderBadge(icon: g.icon, label: g.label, accent: brandColor(g.accent), size: 28)
                Text(g.fullName).font(Typo.section).foregroundStyle(Palette.ink)
                Text("\(g.rows.count) 个账号").font(Typo.small).foregroundStyle(Palette.muted)
                Spacer()
                Button {
                    for r in g.rows where r.enabled && r.canQuery {
                        model.query(r.id)
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .barButton()
                Button {
                    model.openTemplates()
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .barButton()
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(g.rows) { row in
                    AccountCard(model: model, row: row)
                }
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            Rectangle().fill(Palette.border).frame(height: 1)
            cardBody.padding(12)
            Rectangle().fill(Palette.border).frame(height: 1)
            cardFooter.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Palette.border, lineWidth: 1))
        .opacity(row.enabled ? 1 : 0.55)   // 已停用: 降透明度
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openDetail() }
        .contextMenu {
            Button("查询额度") { model.query(row.id) }.disabled(!row.canQuery || !row.enabled)
            Button("打开详情") { openDetail() }
            Divider()
            Button(row.enabled ? "停用监控" : "启用监控") { model.toggleMonitoring(row.id, enabled: !row.enabled) }
            Button("编辑配置") {
                model.selectAccount(row.id)
                model.tab = .config
                model.startEdit()
            }
            Divider()
            Button("删除…", role: .destructive) { model.delete(row.id) }
        }
    }

    private func openDetail() {
        model.selectAccount(row.id)   // 内部 leaveGuard; 双击进详情 (额度 tab)
    }

    // 卡头: 账号名 + 套餐/模式徽章 + 状态点 + ⋯菜单
    private var cardHeader: some View {
        HStack(spacing: 6) {
            Text(row.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                .lineLimit(1).truncationMode(.middle)
            BadgeText(text: row.builtin ? "内置" : (row.authStyle == "apikey" ? "API Key" : "授权登录"),
                      locked: row.builtin)
            if !row.isConfigured { BadgeText(text: "未配置", locked: true) }
            Spacer(minLength: 2)
            HStack(spacing: 4) {
                let (color, word) = row.status
                StatusDot(color: color)
                Text(word).font(Typo.small).foregroundStyle(color)
            }
            Menu {
                Button("查询额度") { model.query(row.id) }.disabled(!row.canQuery || !row.enabled)
                Button("打开详情") { openDetail() }
                Divider()
                Toggle(isOn: monitorBinding) { Text("启用监控") }
                Toggle(isOn: floatingBinding) { Text("悬浮窗显示") }
                Toggle(isOn: hudBinding) { Text("同步 HUD") }
                Divider()
                Button("编辑配置") {
                    model.selectAccount(row.id)
                    model.tab = .config
                    model.startEdit()
                }
                Button("删除…", role: .destructive) { model.delete(row.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
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

    // 卡体: 每窗口一行 (标签 + 进度条已用% + 重置倒计时); 四态/未查询给对应文案
    @ViewBuilder
    private var cardBody: some View {
        if !row.enabled {
            Text("已停用监控：不查询、不调度，不出现在菜单栏与 HUD。")
                .font(Typo.small).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
        } else if !row.isConfigured {
            Text("未配置：凭证或地址缺失，补齐后可查询（详情页可编辑）。")
                .font(Typo.small).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
        } else if let e = row.state?.cache?.error {
            VStack(spacing: 6) {
                Text("查询失败：\(DataEngine.reason(for: e))")
                    .font(Typo.small).foregroundStyle(Palette.danger)
                Text("上次成功查询时间未知；点「查询额度」重试。")
                    .font(Typo.small).foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        } else if rows.isEmpty {
            Text(row.state?.cache == nil ? "尚未查询 — 点「查询额度」获取窗口数据"
                                       : "此账号额度解析待核实（无窗口数据）")
                .font(Typo.small).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
        } else {
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { i in
                    windowRow(rows[i])
                }
            }
        }
    }

    private func windowRow(_ r: (label: String, pct: Double?, amount: Double?, limit: Double?,
                                 unit: String?, period: String?, resetsAt: Int?)) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(r.label).font(Typo.small).foregroundStyle(Palette.muted)
                if let a = r.amount, let l = r.limit {
                    Text(QuotaTabView.unitLabel(a, l, unit: r.unit))
                        .font(Typo.small).foregroundStyle(Palette.muted).monospacedDigit()
                }
                Spacer()
                if let cd = HUDFmt.resetCountdown(r.resetsAt, now: Date()) {
                    Text(cd + " 重置").font(Typo.small).foregroundStyle(Palette.muted).monospacedDigit()
                }
                Text(r.pct != nil ? "\(Int(r.pct!.rounded()))%" : "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(pctColor(r.pct))
                    .frame(width: 44, alignment: .trailing)
            }
            // 进度条方向 = 已用% (与 HUD/statusline 同口径)
            ProgressLine(pct: r.pct)
        }
    }

    private func pctColor(_ p: Double?) -> Color {
        guard let p else { return Palette.muted }
        if p >= 90 { return Palette.danger }
        if p >= 70 { return Palette.warn }
        return Palette.ok
    }

    // 卡脚: 更新时间 + 查询按钮
    private var cardFooter: some View {
        HStack(spacing: 8) {
            Text(model.running.contains(row.id)
                 ? "查询中…"
                 : "更新于 \(formatCacheTime(row.state?.cache?.generatedAt))")
                .font(Typo.small).foregroundStyle(Palette.muted)
            Spacer()
            if row.canQuery {
                Button(model.running.contains(row.id) ? "查询中…" : "查询额度") {
                    model.query(row.id)
                }
                .barButton()
                .disabled(model.running.contains(row.id) || !row.enabled)
            }
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
                    if model.leaveGuard() {
                        model.showingTemplates = false
                        model.draft = nil
                        model.selected = nil
                    }
                } label: {
                    Label("返回总览", systemImage: "chevron.left")
                }
                .barButton()
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Typo.title).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        ForEach(badges, id: \.self) { b in
                            BadgeText(text: b, locked: lockedBadges.contains(b))
                        }
                    }
                }
                Spacer(minLength: 8)
                actions
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

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
        let m = row.plugin.manifest
        var out = [m.fullName, row.authLabel, row.builtin ? "内置 · 地址由模板提供" : "自定义"]
        if !row.enabled { out.append("已停用") }
        return out
    }

    private var lockedBadges: Set<String> {
        var s: Set<String> = ["内置 · 地址由模板提供", "模板新建", "授权登录", "已停用"]
        if let row = model.current, row.builtin { s.insert(row.plugin.manifest.fullName) }
        return s
    }

    @ViewBuilder
    private var actions: some View {
        if model.showingTemplates {
            Button("取消") { model.showingTemplates = false; model.selectAccount(model.selected ?? "") }
                .barButton()
        } else if let d = model.draft, d.isNew {
            Button("返回模板目录") { model.cancelEdit() }.barButton()
        } else if model.draft != nil {
            EmptyView()
        } else if let row = model.current {
            HStack(spacing: 8) {
                // 额度页的主操作才放这里; 编辑按钮贴近内容, 由各 tab 卡片头提供
                if model.tab == .quota, row.canQuery {
                    Button(model.running.contains(row.id) ? "查询中…" : "查询额度") { model.query(row.id) }
                        .barButton(.primary)
                        .disabled(model.running.contains(row.id))
                }
            }
        }
    }

    private var visibleTabs: [SettingsModel.Tab] {
        // 新建模式 (模板直入) 只有配置与自动触发
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
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            // 草稿底栏固定在滚动区外: 配置/自动触发两个 tab 都可见可用 (草稿整体保存)
            if model.draft != nil && !model.showingTemplates {
                draftActionBar
            }
        }
    }

    private var draftActionBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack(spacing: 8) {
                Text(model.draft?.isNew == true ? "新账号保存后加入总览列表"
                                                : "修改仅在保存后生效，保存不发起请求")
                    .font(Typo.small).foregroundStyle(Palette.muted)
                Spacer()
                Button("取消") { model.cancelEdit() }.barButton()
                Button("保存") { model.save() }
                    .barButton(.primary)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Palette.surface)
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
            // 草稿态: 配置/自动触发 tab 各渲染对应段落; 额度 tab 仍看数据 (草稿不丢)
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
    enum Mode { case quota, config, trigger, edit, editTrigger, templates, create, importer, full, overview }
    var mode: Mode
    var slug: String?
    var templateID: String?
    var importModel: ImportCenterModel? = nil
}
