import SwiftUI
import AppKit

// MARK: - 方案 C 设置中心: 单窗口 (左栏账号 + 右栏 额度/配置/自动触发)

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
            SidebarColumn(model: model, engine: engine)
                .frame(width: 240)
            Divider().overlay(Palette.border)
            VStack(spacing: 0) {
                DetailHeader(model: model)
                Rectangle().fill(Palette.border).frame(height: 1)
                DetailPanel(model: model, engine: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.canvas)
            }
        }
        .background(Palette.canvas)
        .overlay(alignment: .bottom) { toastBar }
        .sheet(isPresented: $model.importOpen) {
            ImportCenterSheet(model: model, engine: engine, im: model.importer)
        }
        .background {
            // Esc: 草稿 → 取消 (带确认); 模板目录 → 返回账号
            Button("") {
                if model.draft != nil { model.cancelEdit() }
                else if model.showingTemplates { model.showingTemplates = false }
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
        case .full:
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

// MARK: - 左栏

struct SidebarColumn: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("账号").font(Typo.section).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(engine.allPlugins.count) 个").font(Typo.small).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.accounts.isEmpty {
                        Text(model.search.isEmpty ? "尚无账号" : "没有匹配「\(model.search)」的账号")
                            .font(Typo.small).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    ForEach(model.grouped, id: \.0) { group, rows in
                        HStack {
                            Text(group)
                            Spacer()
                            Text("\(rows.count)")
                        }
                        .font(Typo.small)
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 4)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        ForEach(rows) { row in
                            accountRow(row)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Rectangle().fill(Palette.border).frame(height: 1)
                .padding(.top, 8)

            HStack(spacing: 8) {
                Button("添加账号") { model.openTemplates() }
                    .barButton().frame(maxWidth: .infinity)
                Button("导入…") { model.importOpen = true }
                    .barButton().frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(Palette.sidebar)
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
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, lineWidth: 1))
    }

    private func accountRow(_ row: AccountRow) -> some View {
        let selected = model.selected == row.id && !model.showingTemplates && model.draft?.isNew != true
        let (color, word) = row.status
        return Button {
            model.selectAccount(row.id)
        } label: {
            HStack(spacing: 8) {
                Text(row.name)
                    .font(Typo.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    StatusDot(color: color)
                    Text(word).font(Typo.small).foregroundStyle(color)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Palette.surface : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Palette.border : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(row.name) · \(row.plugin.manifest.fullName)")
        .contextMenu {
            Button("查询额度") { model.query(row.id) }
                .disabled(!row.canQuery)
            Button("编辑配置") {
                model.selectAccount(row.id)
                model.tab = .config
                model.startEdit()
            }
            Divider()
            Button("删除…", role: .destructive) { model.delete(row.id) }
        }
    }
}

// MARK: - 右栏头部

struct DetailHeader: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
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
        if !row.autoQuery { out.append("自动查询已关闭") }
        return out
    }

    private var lockedBadges: Set<String> {
        var s: Set<String> = ["内置 · 地址由模板提供", "模板新建", "授权登录"]
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
            // 草稿态: 额度 tab 仍看数据, 配置/自动触发 tab 显示同一编辑区 (切 tab 不丢草稿)
            if let d = model.draft, model.tab != .quota {
                DraftFormView(model: model, draft: d)
            } else if let d = model.draft, d.isNew {
                DraftFormView(model: model, draft: d)
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
    enum Mode { case quota, config, trigger, edit, templates, create, importer, full }
    var mode: Mode
    var slug: String?
    var templateID: String?
    var importModel: ImportCenterModel? = nil
}
