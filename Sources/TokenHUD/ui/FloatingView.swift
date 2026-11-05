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
    private var chromeHeight: CGFloat { expanded ? 71 : 37 }
    private var estimatedContentHeight: CGFloat {
        if states.isEmpty { return expanded ? 104 : 36 }
        return states.reduce(CGFloat(16)) { height, state in
            let count = max(1, QuotaPresentation(state: state).metrics.count)
            if expanded || controller.style == .glass { return height + 84 + CGFloat((count + 1) / 2) * 56 }
            if controller.style == .compact { return height + 25 }
            if controller.style == .list { return height + CGFloat(count) * 24 + 9 }
            return height + 29 + CGFloat(count) * 20
        }
    }
    private var viewportHeight: CGFloat {
        min(max(1, measuredContentHeight > 0 ? measuredContentHeight : estimatedContentHeight),
            max(1, maximumHeight - chromeHeight))
    }
    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 37)
            if expanded { Rectangle().fill(Palette.border).frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: expanded ? 9 : (controller.style == .compact ? 3 : 12)) {
                    if states.isEmpty { emptyState }
                    ForEach(states) { state in
                        if expanded { floatingAccount(state) }
                        else {
                            switch controller.style {
                            case .compact: inlineAccount(state)
                            case .list: listAccount(state)
                            case .glass: floatingAccount(state)
                            case .card: compactAccount(state)
                            }
                        }
                    }
                }
                .padding(.horizontal, expanded ? 10 : 13)
                .padding(.top, expanded ? 10 : 1)
                .padding(.bottom, expanded ? 10 : (controller.style == .compact ? 4 : 12))
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
                    Button(action: onOpenSettings) { Label("管理账号", systemImage: "slider.horizontal.3") }
                        .buttonStyle(QuickPanelTextStyle())
                    Spacer()
                    Text("\(states.count) 个账号").font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 8).frame(height: 32)
            }
        }
        .frame(width: controller.style.preferredWidth)
        .onAppear { onHeightChange?(min(maximumHeight, chromeHeight + viewportHeight)) }
        .foregroundStyle(Palette.ink)
        .background {
            if controller.style == .glass && !reduceTransparency {
                RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 12).fill(Palette.canvas.opacity(controller.bgOpacity * 0.22)))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Palette.canvas.opacity(reduceTransparency ? 1 : min(1, max(0.45, controller.bgOpacity))))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border, lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button(expanded ? "收起明细" : "展开明细", action: onToggle)
            Button("关闭悬浮速览") { controller.hide() }
            displayControls
            Divider()
            Button("刷新额度", action: onRefreshAll)
            Button("管理账号…", action: onOpenSettings)
            Divider()
            Button("退出 \(AppBrand.name)", action: onQuit)
        }
    }
    private var header: some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(Palette.accent).frame(width: 5, height: 5).accessibilityHidden(true)
                Text("额度速览").font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 23)
            .overlay { FloatingWindowDragArea(onDoubleClick: onToggle) }
            Menu {
                styleChoices
                Divider()
                opacityChoices
            } label: { Image(systemName: "square.grid.2x2") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 23, height: 23).accessibilityLabel("切换悬浮窗样式").help("显示样式")
            if engine.isRefreshingAll {
                ProgressView().controlSize(.mini).frame(width: 23, height: 23)
                    .accessibilityLabel("正在刷新额度")
            } else {
                Button(action: onRefreshAll) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(QuickPanelIconStyle(size: 23))
                    .accessibilityLabel("刷新账号额度").help("刷新额度")
            }
            Button(action: onToggle) { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                .buttonStyle(QuickPanelIconStyle(size: 23))
                .accessibilityLabel(expanded ? "收起悬浮明细" : "展开悬浮明细")
                .help(expanded ? "收起明细" : "展开明细")
            Button { controller.hide() } label: { Image(systemName: "xmark") }
                .buttonStyle(QuickPanelIconStyle(size: 23))
                .accessibilityLabel("关闭悬浮速览").help("关闭悬浮速览")
        }
        .padding(.leading, 13).padding(.trailing, 7).padding(.vertical, 7)
    }
    @ViewBuilder private var displayControls: some View {
        Menu("显示样式") { styleChoices }
        opacityChoices
    }
    private var opacityChoices: some View {
        Menu("背景透明度") {
            ForEach([45, 60, 75, 85, 100], id: \.self) { percent in
                Button("不透明度 \(percent)%") { controller.setBgOpacity(Double(percent) / 100) }
            }
        }
    }
    private var styleChoices: some View {
        Picker("显示样式", selection: Binding(get: { controller.style }, set: { controller.setStyle($0) })) {
            ForEach(PanelStyle.allCases) { style in Text(style.label).tag(style) }
        }
    }
    private func inlineAccount(_ state: ProviderState) -> some View {
        let snapshot = QuotaPresentation(state: state)
        return HStack(spacing: 9) {
            HStack(spacing: 3) {
                Text(state.manifest.fullName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if snapshot.isOld {
                    Text("旧值").font(.system(size: 9)).foregroundStyle(Palette.warn).fixedSize()
                }
            }.frame(width: 72, alignment: .leading)
                .help(snapshot.isOld ? state.manifest.fullName + " · " + snapshot.status : state.manifest.fullName)
            if snapshot.metrics.isEmpty {
                Text(state.manifest.supportsQuota ? snapshot.status : "仅 API")
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
                    }.frame(maxWidth: .infinity).help(metric.label + " · " + metric.value + (snapshot.isOld ? " · 旧值" : ""))
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
                HStack(spacing: 8) {
                    Text(state.manifest.fullName + " · " + compactLabel(metric.label))
                        .font(.system(size: 10.5)).lineLimit(1).frame(width: 102, alignment: .leading)
                    if snapshot.isOld {
                        Text("旧值").font(.system(size: 9)).foregroundStyle(Palette.warn).fixedSize()
                    }
                    if let percentage = metric.percentage {
                        ProgressLine(pct: percentage).opacity(snapshot.isOld ? 0.45 : 1)
                    }
                    Text(metric.value).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(snapshot.isOld ? Palette.muted : Palette.ink)
                        .frame(minWidth: 38, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }.help(metric.label + " · " + metric.value + (snapshot.isOld ? " · 旧值" : ""))
            }
        }.contextMenu { accountMenu(state) }
    }
    private func compactAccount(_ state: ProviderState) -> some View {
        let snapshot = QuotaPresentation(state: state)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(state.manifest.fullName).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 5)
                if !state.manifest.supportsQuota {
                    Text("仅 API").font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                } else if snapshot.isOld {
                    Text("旧值").font(.system(size: 10.5)).foregroundStyle(Palette.warn)
                }
            }
            if state.manifest.supportsQuota {
                if snapshot.metrics.isEmpty {
                    Text(snapshot.status).font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
                ForEach(snapshot.metrics) { metric in
                    HStack(spacing: 8) {
                        Text(compactLabel(metric.label)).font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted).frame(width: 40, alignment: .leading)
                            .lineLimit(1).help(metric.label)
                        if let percentage = metric.percentage {
                            ProgressLine(pct: percentage).opacity(snapshot.isOld ? 0.45 : 1)
                            Text(metric.value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(snapshot.isOld ? Palette.muted : Palette.ink)
                                .frame(minWidth: 38, alignment: .trailing)
                        } else {
                            Text(metric.value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(snapshot.isOld ? Palette.muted : Palette.ink)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if snapshot.isOld && !snapshot.metrics.isEmpty {
                    Text(snapshot.status).font(.system(size: 10)).foregroundStyle(Palette.warn).lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu { accountMenu(state) }
    }
    private func compactLabel(_ label: String) -> String {
        switch label {
        case "5小时": return "5h"
        case "本周": return "周"
        case "本月": return "月"
        default: return label
        }
    }
    private func floatingAccount(_ state: ProviderState) -> some View {
        let snapshot = QuotaPresentation(state: state)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Button { SettingsWindowManager.shared.showAccount(state.slug) } label: {
                    HStack(spacing: 6) {
                        Text(state.manifest.fullName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("打开账号 \(state.manifest.fullName)")
                .help("打开账号配置")
                if state.manifest.supportsQuota, let model = operationModel {
                    FloatingQueryAction(model: model, slug: state.slug, name: state.manifest.fullName)
                }
            }
            if state.manifest.supportsQuota {
                if snapshot.metrics.isEmpty {
                    Text(snapshot.status).font(.system(size: 11)).foregroundStyle(Palette.muted)
                } else {
                    QuotaMetricGrid(metrics: snapshot.metrics, old: snapshot.isOld, compact: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot.isOld ? snapshot.status : snapshot.updated)
                        .foregroundStyle(snapshot.isOld ? Palette.warn : Palette.muted).lineLimit(2)
                    Spacer(minLength: 0)
                    if snapshot.isOld {
                        Text(snapshot.updated).foregroundStyle(Palette.muted).monospacedDigit()
                    }
                }
                .font(.system(size: 10.5))
            } else {
                Text("仅 API 调用").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
        .padding(11)
        .background(Palette.surface.opacity(controller.style == .glass && !reduceTransparency ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border.opacity(0.8), lineWidth: 0.6))
        .contextMenu { accountMenu(state) }
    }
    @ViewBuilder private func accountMenu(_ state: ProviderState) -> some View {
        Button("打开账号") { SettingsWindowManager.shared.showAccount(state.slug) }
        Button("查询额度") { SettingsWindowManager.shared.modelForQuery()?.query(state.slug) }
            .disabled(queryUnavailable(state))
        Divider()
        displayControls
        Divider()
        Button("关闭悬浮速览") { controller.hide() }
        Button("管理账号…", action: onOpenSettings)
    }
    private func queryUnavailable(_ state: ProviderState) -> Bool {
        guard state.manifest.supportsQuota, let model = operationModel,
              let row = model.row(state.slug) else { return true }
        return !model.quotaConfigured(row)
    }
    private var emptyState: some View {
        VStack(alignment: .center, spacing: 7) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 20)).foregroundStyle(Palette.muted)
            Text("暂无显示中的账号").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            Button("管理账号", action: onOpenSettings).buttonStyle(QuickPanelTextStyle())
        }
        .frame(maxWidth: .infinity).padding(.vertical, 15)
    }
    static func time(_ date: Date) -> String { date.formatted(.dateTime.hour().minute().second()) }
}

private struct FloatingQueryAction: View {
    @ObservedObject var model: SettingsModel
    let slug: String
    let name: String
    var body: some View {
        Group {
            if model.running.contains(slug) {
                ProgressView().controlSize(.mini).frame(width: 22, height: 22)
                    .accessibilityLabel("正在查询 \(name)")
            } else {
                Button { model.query(slug) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(QuickPanelIconStyle(size: 22))
                    .disabled(model.row(slug).map { !model.quotaConfigured($0) } ?? true)
                    .accessibilityLabel("查询 \(name) 的额度")
            }
        }
    }
}

private struct FloatingWindowDragArea: NSViewRepresentable {
    let onDoubleClick: () -> Void
    func makeNSView(context: Context) -> FloatingWindowDragView {
        let view = FloatingWindowDragView()
        view.onDoubleClick = onDoubleClick
        view.toolTip = "拖动移动悬浮窗；双击展开或收起"
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("拖动悬浮窗")
        view.setAccessibilityIdentifier("floating.drag-area")
        return view
    }
    func updateNSView(_ view: FloatingWindowDragView, context: Context) {
        view.onDoubleClick = onDoubleClick
    }
}

private final class FloatingWindowDragView: NSView {
    var onDoubleClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
        else { window?.performDrag(with: event) }
    }
}

private struct FloatingContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
