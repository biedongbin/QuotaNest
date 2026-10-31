import SwiftUI

struct PlanPage: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        List {
            Section {
                Text("每个账号独立设置调用时间。按本机时区执行，调用会消耗该账号额度。")
                    .foregroundStyle(.secondary)
            }
            if model.planRows.isEmpty { ContentUnavailableView("尚无调用计划", systemImage: "calendar") }
            ForEach(model.planRows) { row in
                Button { _ = model.selectAccount(row.slug, tab: .trigger) } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.name).font(.headline)
                            Text(row.providerName).font(.caption).foregroundStyle(.secondary)
                            Text(row.times.isEmpty ? "未设置时间" : row.times.joined(separator: "、"))
                                .monospacedDigit().foregroundStyle(.secondary)
                            Text(row.lastOutcome ?? "今日无执行记录").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row.enabled ? "已启用" : (row.pausedByAccount ? "账号停用，已暂停" : "未启用"))
                            .font(.callout).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }.padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.navigationTitle("调用计划")
    }
}

struct GlobalSettingsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine
    var body: some View {
        Form {
            Section("菜单栏") {
                Picker("显示额度", selection: Binding(get: { engine.iconProviderSlug ?? "" }, set: {
                    engine.setIconProvider($0.isEmpty ? nil : $0)
                })) {
                    Text("所有账号最高用量").tag("")
                    ForEach(model.allAccounts.filter { $0.enabled && $0.canQuery }) { row in Text(row.name).tag(row.id) }
                }
                Text("单击开关菜单快览；双击开关悬浮速览；右键打开操作菜单。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let controller = StatusItemController.shared?.panelController {
                PanelAppearanceSettings(controller: controller)
            }
            Section("Claude Code HUD") {
                Text(engine.hudSyncNames.isEmpty ? "尚未选择显示账号" : engine.hudSyncNames.joined(separator: "、"))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                Button("同步 HUD 配置", systemImage: "arrow.triangle.2.circlepath") { model.syncHUD() }
                Text("各账号的展示页面可单独选择 HUD。同步不发起模型调用。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("关于与诊断") {
                LabeledContent("版本", value: Self.appVersion)
                LabeledContent("运行环境", value: engine.nodePathForUI ?? "未找到 Node.js")
                LabeledContent("HUD 目录") { Text(model.hudDir.path).textSelection(.enabled) }
                LabeledContent("账号目录") { Text(model.userDir.path).textSelection(.enabled) }
            }
        }.formStyle(.grouped).navigationTitle("设置与外观")
    }
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}

private struct PanelAppearanceSettings: View {
    @ObservedObject var controller: PanelController
    var body: some View {
        Section("悬浮速览") {
            Toggle("显示悬浮速览", isOn: Binding(get: { controller.isVisible }, set: {
                if $0 { controller.show() } else { controller.hide() }
            }))
            Slider(value: Binding(get: { controller.bgOpacity }, set: { controller.setBgOpacity($0) }), in: 0.45...1) {
                Text("背景不透明度")
            }
            Text("双击展开或收起。可拖动标题区，位置自动保存。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
