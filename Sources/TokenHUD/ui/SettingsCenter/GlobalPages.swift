import SwiftUI

struct PlanPage: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("按本机时区执行；每次调用会消耗账号额度。"))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                if model.planRows.isEmpty { ContentUnavailableView(L10n.tr("尚无调用计划"), systemImage: "calendar") }
                ForEach(model.planRows) { row in
                    Button { _ = model.selectAccount(row.slug, tab: .trigger) } label: {
                        CardBox {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.name).font(.system(size: 13, weight: .medium))
                                    Text(row.providerName).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    Text(row.times.isEmpty ? L10n.tr("未设置时间") : row.times.joined(separator: "、"))
                                        .monospacedDigit().foregroundStyle(Palette.inkSecondary)
                                    Text(row.lastOutcome ?? L10n.tr("今日无执行记录")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 8)
                                Text(row.enabled ? L10n.tr("已启用") : (row.pausedByAccount ? L10n.tr("账号停用，已暂停") : L10n.tr("未启用")))
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
    private var hudSelectionSummary: String {
        let names = model.allAccounts.filter { $0.enabled && !engine.hudHiddenSlugs.contains($0.id) }.map(\.name)
        return names.isEmpty ? L10n.tr("尚未选择显示账号")
            : names.joined(separator: AppLanguageSettings.shared.selection == .english ? ", " : "、")
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox(L10n.tr("语言")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(L10n.tr("界面语言"), selection: Binding(
                            get: { AppLanguageSettings.shared.selection },
                            set: { AppLanguageSettings.shared.selection = $0 })) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.label).tag(language)
                            }
                        }.pickerStyle(.menu).accessibilityIdentifier("settings.language")
                        Text(L10n.tr("切换立即生效并保存；账号名称和供应商返回的原始内容保持原样。"))
                            .font(Typo.small).foregroundStyle(Palette.muted)
                    }
                }
                GroupBox(L10n.tr("菜单栏")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(L10n.tr("显示额度"), selection: Binding(get: { engine.iconProviderSlug ?? "" }, set: {
                            engine.setIconProvider($0.isEmpty ? nil : $0)
                        })) {
                            Text(L10n.tr("所有账号最高用量")).tag("")
                            ForEach(model.allAccounts.filter { $0.enabled && $0.canQuery }) { row in Text(row.name).tag(row.id) }
                        }
                        Text(L10n.tr("单击开关菜单快览；双击开关悬浮速览；右键打开操作菜单。"))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                if let controller = StatusItemController.shared?.panelController {
                    PanelAppearanceSettings(controller: controller)
                }
                GroupBox("Claude Code HUD") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(hudSelectionSummary)
                                .foregroundStyle(Palette.inkSecondary).textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button(L10n.tr("同步配置"), systemImage: "arrow.triangle.2.circlepath") { model.syncHUD() }.barButton()
                        }
                        if model.allAccounts.isEmpty {
                            Text(L10n.tr("暂无供应商账号，请先添加或导入。"))
                                .font(Typo.small).foregroundStyle(Palette.muted)
                        }
                        HUDAccountFlowLayout {
                            ForEach(model.allAccounts) { row in
                                Toggle(isOn: Binding(
                                    get: { !engine.hudHiddenSlugs.contains(row.id) },
                                    set: { model.toggleHudSync(row.id, synced: $0) })) {
                                    HStack(spacing: 6) {
                                        ProviderLogo(manifest: row.plugin.manifest, slug: row.id, size: 16)
                                        Text(row.name).lineLimit(1)
                                        if !row.enabled {
                                            Text(L10n.tr("已停用"))
                                                .font(Typo.small).foregroundStyle(Palette.muted)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .help(row.enabled ? row.name : row.name + " · " + L10n.tr("已停用，启用后显示"))
                                .accessibilityIdentifier("settings.hud-account.\(row.id)")
                            }
                        }
                        Text(L10n.tr("与「供应商 → 显示」共用同一设置，修改立即同步到 HUD；停用账号保留选择，启用后恢复显示。"))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                AccountDisplayOrderSettings(engine: engine)
                GroupBox(L10n.tr("关于与诊断")) {
                    VStack(spacing: 10) {
                        LabeledContent(L10n.tr("版本"), value: Self.appVersion)
                        Divider()
                        LabeledContent(L10n.tr("运行环境"), value: engine.nodePathForUI ?? L10n.tr("未找到 Node.js"))
                        Divider()
                        LabeledContent(L10n.tr("HUD 目录")) { Text(model.hudDir.path).textSelection(.enabled) }
                        Divider()
                        LabeledContent(L10n.tr("账号目录")) { Text(model.userDir.path).textSelection(.enabled) }
                    }.font(.system(size: 12))
                }
            }.frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
                .padding(.horizontal, 20).padding(.bottom, 20)
        }
    }
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}

/// Keep each checkbox at its natural width, wrapping when the available row is full.
private struct HUDAccountFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 18
    var verticalSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, item) in result.items.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                                  anchor: .topLeading, proposal: ProposedViewSize(item.size))
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, items: [CGRect]) {
        let available = width.flatMap { $0.isFinite ? max(0, $0) : nil }
        var items: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, available ?? ideal.width), height: nil))
            if let available, x > 0, x + size.width > available {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            items.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: available ?? usedWidth, height: items.isEmpty ? 0 : y + rowHeight), items)
    }
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
        GroupBox(L10n.tr("悬浮窗显示顺序")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ordered.enumerated()), id: \.element.slug) { index, provider in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(Palette.muted).frame(width: 20)
                        Text(provider.manifest.fullName).lineLimit(1)
                        Spacer()
                        Button { move(provider.slug, by: -1) } label: { Image(systemName: "chevron.up") }
                            .barButton().disabled(index == 0).accessibilityLabel(L10n.tr("上移 %@", provider.manifest.fullName))
                        Button { move(provider.slug, by: 1) } label: { Image(systemName: "chevron.down") }
                            .barButton().disabled(index == ordered.count - 1).accessibilityLabel(L10n.tr("下移 %@", provider.manifest.fullName))
                    }.font(Typo.body)
                }
                Text(L10n.tr("用上下箭头调整，立即生效并保存；未显示的账号保留位置。菜单快览仍按供应商分组。"))
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
        GroupBox(L10n.tr("悬浮速览")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L10n.tr("显示悬浮速览"), isOn: Binding(get: { controller.isVisible }, set: {
                    if $0 { controller.show() } else { controller.hide() }
                })).toggleStyle(.switch).controlSize(.small)
                Picker(L10n.tr("显示样式"), selection: Binding(get: { controller.style }, set: { controller.setStyle($0) })) {
                    ForEach(PanelStyle.allCases) { style in Text(style.label).tag(style) }
                }.pickerStyle(.menu)
                Text(controller.style == .compact ? L10n.tr("紧凑：每个账号一行，同时显示多个额度窗口。") : L10n.tr("样式切换立即生效并保存。"))
                    .font(Typo.small).foregroundStyle(Palette.muted)
                HStack(spacing: 16) {
                    Text(L10n.tr("背景不透明度"))
                    Slider(value: Binding(get: { controller.bgOpacity }, set: { controller.setBgOpacity($0) }), in: 0.45...1)
                        .frame(maxWidth: 230).accessibilityLabel(L10n.tr("背景不透明度"))
                    Text("\(Int(controller.bgOpacity * 100))%").monospacedDigit().foregroundStyle(Palette.muted)
                }
                Text(L10n.tr("双击展开或收起。拖动悬浮窗任意位置，位置自动保存；点击显示标题，离开 5 秒后隐藏。"))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }
}
