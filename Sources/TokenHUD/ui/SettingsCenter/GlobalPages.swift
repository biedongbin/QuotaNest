import SwiftUI

struct PlanPage: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("按本机时区执行；每次调用会消耗账号额度。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                if model.planRows.isEmpty { ContentUnavailableView("尚无调用计划", systemImage: "calendar") }
                ForEach(model.planRows) { row in
                    Button { _ = model.selectAccount(row.slug, tab: .trigger) } label: {
                        CardBox {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.name).font(.system(size: 13, weight: .medium))
                                    Text(row.providerName).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    Text(row.times.isEmpty ? "未设置时间" : row.times.joined(separator: "、"))
                                        .monospacedDigit().foregroundStyle(Palette.inkSecondary)
                                    Text(row.lastOutcome ?? "今日无执行记录").font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 8)
                                Text(row.enabled ? "已启用" : (row.pausedByAccount ? "账号停用，已暂停" : "未启用"))
                                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                Image(systemName: "chevron.right").foregroundStyle(Palette.muted)
                            }.contentShape(Rectangle())
                        }
                    }.buttonStyle(.plain)
                }
            }.frame(maxWidth: 1200, alignment: .leading).frame(maxWidth: .infinity)
                .padding(.horizontal, 20).padding(.bottom, 20)
        }
    }
}

struct GlobalSettingsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("菜单栏") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("显示额度", selection: Binding(get: { engine.iconProviderSlug ?? "" }, set: {
                            engine.setIconProvider($0.isEmpty ? nil : $0)
                        })) {
                            Text("所有账号最高用量").tag("")
                            ForEach(model.allAccounts.filter { $0.enabled && $0.canQuery }) { row in Text(row.name).tag(row.id) }
                        }
                        Text("单击开关菜单快览；双击开关悬浮速览；右键打开操作菜单。")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                if let controller = StatusItemController.shared?.panelController {
                    PanelAppearanceSettings(controller: controller)
                }
                AccountDisplayOrderSettings(engine: engine)
                GroupBox("Claude Code HUD") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(engine.hudSyncNames.isEmpty ? "尚未选择显示账号" : engine.hudSyncNames.joined(separator: "、"))
                                .foregroundStyle(Palette.inkSecondary).textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button("同步配置", systemImage: "arrow.triangle.2.circlepath") { model.syncHUD() }.barButton()
                        }
                        Text("在账号的展示页选择 HUD。同步不发起模型调用。")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                GroupBox("关于与诊断") {
                    VStack(spacing: 10) {
                        LabeledContent("版本", value: Self.appVersion)
                        Divider()
                        LabeledContent("运行环境", value: engine.nodePathForUI ?? "未找到 Node.js")
                        Divider()
                        LabeledContent("HUD 目录") { Text(model.hudDir.path).textSelection(.enabled) }
                        Divider()
                        LabeledContent("账号目录") { Text(model.userDir.path).textSelection(.enabled) }
                    }.font(.system(size: 12))
                }
            }.frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
                .padding(.horizontal, 20).padding(.bottom, 20)
        }
    }
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}

private struct AccountDisplayOrderSettings: View {
    @ObservedObject var engine: DataEngine
    private var ordered: [PluginProvider] {
        let byID = Dictionary(uniqueKeysWithValues: engine.allPlugins.map { ($0.slug, $0) })
        let saved = engine.providerOrder.compactMap { byID[$0] }
        let known = Set(saved.map(\.slug))
        return saved + engine.allPlugins.filter { !known.contains($0.slug) }
    }
    var body: some View {
        GroupBox("悬浮窗显示顺序") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ordered.enumerated()), id: \.element.slug) { index, provider in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(Palette.muted).frame(width: 20)
                        Text(provider.manifest.fullName).lineLimit(1)
                        Spacer()
                        Button { move(provider.slug, by: -1) } label: { Image(systemName: "chevron.up") }
                            .barButton().disabled(index == 0).accessibilityLabel("上移 \(provider.manifest.fullName)")
                        Button { move(provider.slug, by: 1) } label: { Image(systemName: "chevron.down") }
                            .barButton().disabled(index == ordered.count - 1).accessibilityLabel("下移 \(provider.manifest.fullName)")
                    }.font(Typo.body)
                }
                Text("用上下箭头调整，立即生效并保存；未显示的账号保留位置。菜单快览仍按供应商分组。")
                    .font(Typo.small).foregroundStyle(Palette.muted)
            }
        }
    }
    private func move(_ slug: String, by offset: Int) {
        var ids = ordered.map(\.slug)
        guard let index = ids.firstIndex(of: slug), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        engine.setProviderOrder(ids)
    }
}

private struct PanelAppearanceSettings: View {
    @ObservedObject var controller: PanelController
    var body: some View {
        GroupBox("悬浮速览") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("显示悬浮速览", isOn: Binding(get: { controller.isVisible }, set: {
                    if $0 { controller.show() } else { controller.hide() }
                })).toggleStyle(.switch).controlSize(.small)
                Picker("显示样式", selection: Binding(get: { controller.style }, set: { controller.setStyle($0) })) {
                    ForEach(PanelStyle.allCases) { style in Text(style.label).tag(style) }
                }.pickerStyle(.menu)
                Text(controller.style == .compact ? "紧凑：每个账号一行，同时显示多个额度窗口。" : "样式切换立即生效并保存。")
                    .font(Typo.small).foregroundStyle(Palette.muted)
                HStack(spacing: 16) {
                    Text("背景不透明度")
                    Slider(value: Binding(get: { controller.bgOpacity }, set: { controller.setBgOpacity($0) }), in: 0.45...1)
                        .frame(maxWidth: 230).accessibilityLabel("背景不透明度")
                    Text("\(Int(controller.bgOpacity * 100))%").monospacedDigit().foregroundStyle(Palette.muted)
                }
                Text("双击展开或收起。拖动标题区，位置自动保存。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }
}
