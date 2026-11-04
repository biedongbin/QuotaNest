import SwiftUI

struct AccountDetailView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine
    @State private var showDisplay = false

    var body: some View {
        VStack(spacing: 0) {
            if let row = model.current, model.draft?.isNew != true {
                header(row)
            } else {
                HStack(spacing: 14) {
                    QuietTabs(selection: sectionBinding, items: [("config", "基础接入与用量"), ("trigger", "API 调度")])
                    Spacer(minLength: 0)
                    Text("保存后加入账号列表").font(Typo.small).foregroundStyle(Palette.muted)
                }.padding(.horizontal, 20).padding(.vertical, 10)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.topError.isEmpty {
                        ResultBox(kind: .error, title: "请检查配置", detail: model.topError)
                    }
                    content
                }
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(20)
            }
            if model.draft != nil { draftActions }
        }
        .navigationTitle("TokenHUD")
        .onChange(of: model.selected) { _, _ in showDisplay = false }
        .onChange(of: model.tab) { _, _ in showDisplay = false }
        .onChange(of: model.draft?.isNew) { _, _ in showDisplay = false }
    }

    private func header(_ row: AccountRow) -> some View {
        HStack(spacing: 14) {
            QuietTabs(selection: sectionBinding, items: [("config", "基础接入与用量"), ("quota", "额度"), ("trigger", "API 调度"), ("display", "展示")])
            Spacer(minLength: 0)
            Toggle("启用账号", isOn: Binding(get: { row.enabled }, set: { model.toggleMonitoring(row.id, enabled: $0) }))
                .toggleStyle(.switch).controlSize(.small).fixedSize().font(Typo.small)
                .help("立即生效；停用后暂停后台查询和调用计划，保留配置。")
        }.padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var sectionBinding: Binding<String> {
        Binding(get: { showDisplay ? "display" : model.tab.rawValue }, set: { section in
            if section == "display" { showDisplay = true }
            else { model.tab = SettingsModel.Tab(rawValue: section) ?? .config; showDisplay = false }
        })
    }
    @ViewBuilder private var content: some View {
        if showDisplay, let row = model.current {
            AccountDisplaySettings(model: model, row: row)
        } else if let draft = model.draft {
            if !draft.isNew && model.tab == .quota, let row = model.current {
                QuotaTabView(model: model, row: row)
            } else {
                DraftFormView(model: model, draft: draft, section: model.tab == .trigger ? .trigger : .config)
            }
        } else if let row = model.current {
            switch model.tab {
            case .config: ConfigTabView(model: model, row: row)
            case .quota: QuotaTabView(model: model, row: row)
            case .trigger: TriggerTabView(model: model, row: row)
            }
        } else {
            ContentUnavailableView("选择一个账号", systemImage: "person.crop.circle")
        }
    }
    private var draftActions: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Label("未保存的更改", systemImage: "pencil.circle").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.cancelEdit() }.barButton().keyboardShortcut(.cancelAction)
                Button("保存") { model.save() }
                    .barButton(.primary).keyboardShortcut("s", modifiers: .command)
                    .disabled(model.isTestingCurrentConfig || model.draftConfigurationReadOnly)
            }.padding(.horizontal, 20).frame(minHeight: 48).background(Palette.surface)
        }
    }
}

struct AccountDisplaySettings: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("显示位置") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("菜单快览与悬浮速览", isOn: Binding(get: {
                        !model.engine.floatingHiddenSlugs.contains(row.id)
                    }, set: { model.toggleFloating(row.id, shown: $0) }))
                    Toggle("Claude Code HUD", isOn: Binding(get: {
                        !model.engine.hudHiddenSlugs.contains(row.id)
                    }, set: { model.toggleHudSync(row.id, synced: $0) }))
                    Text("立即生效。停用的账号保留展示选择，重新启用后恢复显示。")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(8)
            }
            GroupBox("菜单栏图标") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("用此账号的额度作为菜单栏数字", isOn: Binding(get: {
                        model.engine.iconProviderSlug == row.id
                    }, set: { model.engine.setIconProvider($0 ? row.id : nil) }))
                        .disabled(!row.enabled || !row.canQuery)
                    Text("取消指定后，显示所有已启用账号的最高已用比例；旧数据会注明。")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(8)
            }
        }
    }
}
