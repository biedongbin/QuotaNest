import AppKit
import SwiftUI

struct FloatingView: View {
    @ObservedObject var engine: DataEngine
    @ObservedObject var controller: PanelController
    let expanded: Bool
    let onToggle: () -> Void
    var onQuit: () -> Void = {}
    var onRefreshAll: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var operationModel: SettingsModel? = nil
    var maximumHeight: CGFloat = .greatestFiniteMagnitude
    var onHeightChange: ((CGFloat) -> Void)? = nil
    @State private var measuredContentHeight: CGFloat = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var states: [ProviderState] {
        engine.states.filter { !engine.floatingHiddenSlugs.contains($0.slug) }
    }
    private var chromeHeight: CGFloat { (controller.titleVisible ? 37 : 0) + (expanded ? 34 : 0) }
    private var estimatedContentHeight: CGFloat {
        if states.isEmpty { return 70 }
        return states.reduce(CGFloat(20)) { height, state in
            let count = max(1, QuotaPresentation(state: state).metrics.count)
            if expanded || controller.style == .card { return height + 118 + (expanded ? 24 : 0) }
            if controller.style == .glass { return height + 100 }
            if controller.style == .compact { return height + 24 }
            return height + CGFloat(count) * 22 + 16
        }
    }
    private var listNameWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let natural = states.map { ($0.manifest.fullName as NSString).size(withAttributes: [.font: font]).width + 19 }.max() ?? 50
        return min(90, max(50, natural))
    }
    private var listPeriodWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 10)
        let natural = states.flatMap { QuotaPresentation(state: $0).metrics }.map {
            (compactLabel($0.label) as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 18
        return min(44, max(18, natural))
    }
    private var viewportHeight: CGFloat {
        min(max(1, measuredContentHeight > 0 ? measuredContentHeight : estimatedContentHeight),
            max(1, maximumHeight - chromeHeight))
    }
    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: controller.titleVisible ? 37 : 0)
                .clipped().opacity(controller.titleVisible ? 1 : 0)
                .accessibilityHidden(!controller.titleVisible)
            if expanded && controller.titleVisible { Rectangle().fill(Palette.border).frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if states.isEmpty { emptyState }
                    ForEach(Array(states.enumerated()), id: \.element.slug) { index, state in
                        if index > 0 {
                            if expanded || controller.style == .card {
                                Color.clear.frame(height: 9)
                            } else if controller.style == .compact {
                                Color.clear.frame(height: 4)
                            } else {
                                Rectangle().fill(Palette.inkSecondary.opacity(0.22))
                                    .frame(maxWidth: .infinity).frame(height: 1)
                                    .padding(.vertical, controller.style == .glass ? 11 : 8)
                            }
                        }
                        if expanded { cardAccount(state, detailed: true) }
                        else {
                            switch controller.style {
                            case .compact: inlineAccount(state)
                            case .list: listAccount(state)
                            case .glass: glassAccount(state)
                            case .card: cardAccount(state)
                            }
                        }
                    }
                }
                .padding(.horizontal, controller.style == .card || expanded ? 10 : 12)
                .padding(.vertical, 10)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: FloatingContentHeightKey.self, value: geometry.size.height)
                })
                .contentShape(Rectangle()).onTapGesture(count: 2, perform: onToggle)
            }
            .frame(height: viewportHeight)
            .onPreferenceChange(FloatingContentHeightKey.self) { height in
                guard height.isFinite && height > 0 else { return }
                if abs(measuredContentHeight - height) > 0.5 { measuredContentHeight = height }
                onHeightChange?(min(maximumHeight, chromeHeight + height))
            }
            if expanded {
                Rectangle().fill(Palette.border).frame(height: 1)
                HStack {
                    Button(action: onOpenSettings) { Label(L10n.tr("管理账号"), systemImage: "slider.horizontal.3") }
                        .buttonStyle(QuickPanelTextStyle())
                    Spacer()
                    Text(L10n.tr("%@ 个账号", String(describing: states.count))).font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 8).frame(height: 32)
            }
        }
        .frame(width: controller.style.preferredWidth)
        .onAppear { onHeightChange?(min(maximumHeight, chromeHeight + viewportHeight)) }
        .onHover { controller.pointerPresenceChanged($0) }
        .onChange(of: controller.titleVisible) { _, _ in
            onHeightChange?(min(maximumHeight, chromeHeight + viewportHeight))
        }
        .foregroundStyle(Palette.ink)
        .background {
            if controller.style == .glass && !reduceTransparency {
                RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 14).fill(Palette.canvas.opacity(controller.bgOpacity * 0.12)))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Palette.canvas.opacity(reduceTransparency ? 1 : min(1, max(0.45, controller.bgOpacity))))
            }
        }
        .overlay {
            if controller.style == .glass && !reduceTransparency {
                RoundedRectangle(cornerRadius: 14).strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.32), Palette.border.opacity(0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
            } else {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border, lineWidth: 0.8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: controller.style == .glass ? 14 : 12))
        .contextMenu {
            Button(expanded ? L10n.tr("收起明细") : L10n.tr("展开明细"), action: onToggle)
            Button(L10n.tr("关闭悬浮速览")) { controller.hide() }
            displayControls
            Divider()
            Button(L10n.tr("刷新额度"), action: onRefreshAll)
            Button(L10n.tr("管理账号…"), action: onOpenSettings)
            Divider()
            Button(L10n.tr("退出 %@", String(describing: AppBrand.name)), action: onQuit)
        }
        .appLanguageEnvironment()
    }
    private var header: some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(Palette.accent).frame(width: 5, height: 5).accessibilityHidden(true)
                Text(L10n.tr("额度速览")).font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 23)
            .contentShape(Rectangle()).onTapGesture(count: 2, perform: onToggle)
            Menu {
                styleChoices
                Divider()
                opacityChoices
            } label: { Image(systemName: "square.grid.2x2") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 23, height: 23).accessibilityLabel(L10n.tr("切换悬浮窗样式")).help(L10n.tr("显示样式"))
            if engine.isRefreshingAll {
                ProgressView().controlSize(.mini).frame(width: 23, height: 23)
                    .accessibilityLabel(L10n.tr("正在刷新额度"))
            } else {
                Button(action: onRefreshAll) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(QuickPanelIconStyle(size: 23))
                    .accessibilityLabel(L10n.tr("刷新账号额度")).help(L10n.tr("刷新额度"))
            }
            Button(action: onToggle) { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                .buttonStyle(QuickPanelIconStyle(size: 23))
                .accessibilityLabel(expanded ? L10n.tr("收起悬浮明细") : L10n.tr("展开悬浮明细"))
                .help(expanded ? L10n.tr("收起明细") : L10n.tr("展开明细"))
            Button { controller.hide() } label: { Image(systemName: "xmark") }
                .buttonStyle(QuickPanelIconStyle(size: 23))
                .accessibilityLabel(L10n.tr("关闭悬浮速览")).help(L10n.tr("关闭悬浮速览"))
        }
        .padding(.leading, 13).padding(.trailing, 7).padding(.vertical, 7)
    }
    @ViewBuilder private var displayControls: some View {
        Menu(L10n.tr("显示样式")) { styleChoices }
        opacityChoices
    }
    private var opacityChoices: some View {
        Menu(L10n.tr("背景透明度")) {
            ForEach([45, 60, 75, 85, 100], id: \.self) { percent in
                Button(L10n.tr("不透明度 %@%%", String(describing: percent))) { controller.setBgOpacity(Double(percent) / 100) }
            }
        }
    }
    private var styleChoices: some View {
        Picker(L10n.tr("显示样式"), selection: Binding(get: { controller.style }, set: { controller.setStyle($0) })) {
            ForEach(PanelStyle.allCases) { style in Text(style.label).tag(style) }
        }
    }
    private func inlineAccount(_ state: ProviderState) -> some View {
        let snapshot = QuotaPresentation(state: state)
        return HStack(spacing: 7) {
            HStack(spacing: 3) {
                ProviderLogo(manifest: state.manifest, slug: state.slug, size: 13)
                Text(state.manifest.fullName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if state.manifest.supportsQuota && snapshot.isOld {
                    Text(L10n.tr("旧值")).font(.system(size: 9)).foregroundStyle(Palette.warn).fixedSize()
                }
            }.frame(width: listNameWidth, alignment: .leading)
                .help(snapshot.isOld ? state.manifest.fullName + " · " + snapshot.status : state.manifest.fullName)
            if snapshot.metrics.isEmpty {
                Text(state.manifest.supportsQuota ? snapshot.status : L10n.tr("仅 API"))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                ForEach(snapshot.metrics) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 2) {
                            Text(compactLabel(metric.label)).foregroundStyle(Palette.muted)
                            Spacer(minLength: 0)
                            Text(metric.value).monospacedDigit().foregroundStyle(snapshot.isOld ? Palette.muted : Palette.ink)
                                .lineLimit(2).minimumScaleFactor(0.85)
                        }.font(.system(size: 10))
                        if let percentage = metric.percentage {
                            ProgressLine(pct: percentage).opacity(snapshot.isOld ? 0.45 : 1)
                        }
                    }.frame(maxWidth: .infinity).help(metric.label + " · " + metric.value + (snapshot.isOld ? L10n.tr(" · 旧值") : ""))
                }
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .contextMenu { accountMenu(state) }
    }
    private func listAccount(_ state: ProviderState) -> some View {
        let snapshot = QuotaPresentation(state: state)
        return VStack(alignment: .leading, spacing: 7) {
            if snapshot.metrics.isEmpty { inlineAccount(state) }
            ForEach(snapshot.metrics) { metric in
                let summary = "\(state.manifest.fullName) · \(metric.label) · \(metric.value)"
                let tooltip = snapshot.isOld ? summary + " · " + snapshot.status : summary
                HStack(spacing: 5) {
                    HStack(spacing: 5) {
                        ProviderLogo(manifest: state.manifest, slug: state.slug, size: 13)
                        Text(state.manifest.fullName).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    }.frame(width: listNameWidth, alignment: .leading)
                    Text(compactLabel(metric.label)).font(.system(size: 10))
                        .foregroundStyle(Palette.muted).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: listPeriodWidth, alignment: .leading)
                    if let percentage = metric.percentage {
                        ProgressLine(pct: percentage).opacity(snapshot.isOld ? 0.45 : 1)
                    } else {
                        Color.clear.frame(height: 3)
                    }
                    Text(metric.value).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(snapshot.isOld ? Palette.muted : Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .frame(width: 42, alignment: .trailing)
                }
                .help(tooltip)
            }
        }.contextMenu { accountMenu(state) }
    }

    private func accountHeading(_ state: ProviderState, snapshot: QuotaPresentation) -> some View {
        HStack(spacing: 7) {
            ProviderLogo(manifest: state.manifest, slug: state.slug, size: 19)
            Button { SettingsWindowManager.shared.showAccount(state.slug) } label: {
                Text(state.manifest.fullName).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("打开账号配置"))
            if state.manifest.supportsQuota && snapshot.isOld {
                Text(L10n.tr("旧值")).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.warn).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Palette.warn.opacity(0.1), in: Capsule())
            }
            if state.manifest.supportsQuota, let model = operationModel {
                FloatingQueryAction(model: model, slug: state.slug, name: state.manifest.fullName)
            }
        }.frame(minHeight: 22)
    }

    private func cardAccount(_ state: ProviderState, detailed: Bool = false) -> some View {
        let snapshot = QuotaPresentation(state: state)
        let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: min(3, max(1, snapshot.metrics.count)))
        return VStack(alignment: .leading, spacing: 11) {
            accountHeading(state, snapshot: snapshot)
            if snapshot.metrics.isEmpty {
                Text(state.manifest.supportsQuota ? snapshot.status : L10n.tr("仅 API 调用"))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(snapshot.metrics) { metric in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(compactLabel(metric.label)).font(.system(size: 10))
                                .foregroundStyle(Palette.muted).lineLimit(1).help(metric.label)
                            Text(metric.value).font(.system(size: 20, weight: .semibold, design: .rounded))
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                                .foregroundStyle(snapshot.isOld ? Palette.muted : Palette.ink)
                            if let percentage = metric.percentage {
                                ProgressLine(pct: percentage).opacity(snapshot.isOld ? 0.45 : 1)
                            }
                            if detailed, let reset = metric.resetDescription {
                                Text(reset).font(.system(size: 9)).foregroundStyle(Palette.muted)
                                    .lineLimit(1).help(reset)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if state.manifest.supportsQuota && (detailed || snapshot.isOld) {
                Text(snapshot.isOld ? snapshot.status : snapshot.updated)
                    .font(.system(size: 9.5)).foregroundStyle(snapshot.isOld ? Palette.warn : Palette.muted).lineLimit(2)
            }
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.border.opacity(0.85), lineWidth: 0.6))
        .contextMenu { accountMenu(state) }
    }

    private func glassAccount(_ state: ProviderState) -> some View {
        let snapshot = QuotaPresentation(state: state)
        let primary = snapshot.metrics.filter { $0.percentage != nil }.max {
            ($0.percentage ?? 0) < ($1.percentage ?? 0)
        } ?? snapshot.metrics.first
        return VStack(alignment: .leading, spacing: 10) {
            accountHeading(state, snapshot: snapshot)
            if let primary {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(primary.value).font(.system(size: 27, weight: .medium, design: .rounded))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text(compactLabel(primary.label)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if let percentage = primary.percentage {
                            ProgressLine(pct: percentage).opacity(snapshot.isOld ? 0.45 : 1)
                        }
                        Text(snapshot.isOld ? snapshot.status : snapshot.updated)
                            .font(.system(size: 9.5)).foregroundStyle(snapshot.isOld ? Palette.warn : Palette.muted).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                let secondary = snapshot.metrics.filter { $0.id != primary.id }
                if !secondary.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(secondary) { metric in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(compactLabel(metric.label)).foregroundStyle(Palette.muted).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(metric.value).monospacedDigit().fontWeight(.semibold).lineLimit(1)
                            }.font(.system(size: 10.5)).frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                Text(state.manifest.supportsQuota ? snapshot.status : L10n.tr("仅 API 调用"))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 2).padding(.vertical, 2)
        .contextMenu { accountMenu(state) }
    }

    private func compactLabel(_ label: String) -> String {
        let english = AppLanguageSettings.shared.selection == .english
        switch label {
        case "5小时", "5 hours": return "5h"
        case "本周", "This week": return english ? "Week" : "周"
        case "本月", "This month": return english ? "Month" : "月"
        default: return label
        }
    }
    @ViewBuilder private func accountMenu(_ state: ProviderState) -> some View {
        Button(L10n.tr("打开账号")) { SettingsWindowManager.shared.showAccount(state.slug) }
        Button(L10n.tr("查询额度")) { SettingsWindowManager.shared.modelForQuery()?.query(state.slug) }
            .disabled(queryUnavailable(state))
        Divider()
        displayControls
        Divider()
        Button(L10n.tr("关闭悬浮速览")) { controller.hide() }
        Button(L10n.tr("管理账号…"), action: onOpenSettings)
    }
    private func queryUnavailable(_ state: ProviderState) -> Bool {
        guard state.manifest.supportsQuota, let model = operationModel,
              let row = model.row(state.slug) else { return true }
        return !model.quotaConfigured(row)
    }
    private var emptyState: some View {
        VStack(alignment: .center, spacing: 7) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 20)).foregroundStyle(Palette.muted)
            Text(L10n.tr("暂无显示中的账号")).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            Button(L10n.tr("管理账号"), action: onOpenSettings).buttonStyle(QuickPanelTextStyle())
        }
        .frame(maxWidth: .infinity).padding(.vertical, 15)
    }
    static func time(_ date: Date) -> String { date.formatted(.dateTime.hour().minute().second().locale(L10n.locale)) }
}

private struct FloatingQueryAction: View {
    @ObservedObject var model: SettingsModel
    let slug: String
    let name: String
    var body: some View {
        Group {
            if model.running.contains(slug) {
                ProgressView().controlSize(.mini).frame(width: 22, height: 22)
                    .accessibilityLabel(L10n.tr("正在查询 %@", String(describing: name)))
            } else {
                Button { model.query(slug) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(QuickPanelIconStyle(size: 22))
                    .disabled(model.row(slug).map { !model.quotaConfigured($0) } ?? true)
                    .accessibilityLabel(L10n.tr("查询 %@ 的额度", String(describing: name)))
            }
        }
    }
}

private struct FloatingContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
