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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var states: [ProviderState] {
        engine.states.filter { !engine.floatingHiddenSlugs.contains($0.slug) }
    }
    private var expandedHeight: CGFloat {
        let content = states.reduce(CGFloat(0)) { height, state in
            let metrics = QuotaPresentation(state: state).metrics
            let rows = max(1, Int(ceil(Double(metrics.count) / 2)))
            return height + 66 + CGFloat(rows) * 55
        }
        return min(350, max(104, content + 16))
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                Rectangle().fill(Palette.border).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        if states.isEmpty { emptyState }
                        ForEach(states) { state in floatingAccount(state) }
                    }
                    .padding(10)
                }
                .frame(height: expandedHeight)
                Rectangle().fill(Palette.border).frame(height: 1)
                HStack {
                    Button(action: onOpenSettings) { Label("管理账号", systemImage: "slider.horizontal.3") }
                        .buttonStyle(QuickPanelTextStyle())
                    Spacer()
                    Text("\(states.count) 个账号").font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
            } else {
                VStack(spacing: 9) {
                    if states.isEmpty {
                        Text("暂无显示中的账号").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                    ForEach(Array(states.prefix(3))) { state in compactAccount(state) }
                    if states.count > 3 {
                        Button("另外 \(states.count - 3) 个账号") { onToggle() }
                            .font(.system(size: 10.5)).foregroundStyle(Palette.muted).buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 13).padding(.top, 1).padding(.bottom, 12)
                .contentShape(Rectangle()).onTapGesture(count: 2, perform: onToggle)
            }
        }
        .frame(width: 340)
        .foregroundStyle(Palette.ink)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Palette.canvas.opacity(reduceTransparency ? 1 : min(1, max(0.45, controller.bgOpacity))))
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border, lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button(expanded ? "收起明细" : "展开明细", action: onToggle)
            Button("关闭悬浮速览") { controller.hide() }
            Divider()
            Button("刷新额度", action: onRefreshAll)
            Button("管理账号…", action: onOpenSettings)
            Divider()
            Button("退出 TokenHUD", action: onQuit)
        }
    }
    private var header: some View {
        HStack(spacing: 7) {
            Circle().fill(Palette.accent).frame(width: 5, height: 5).accessibilityHidden(true)
            Text("额度速览").font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 0)
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onToggle)
    }
    private func compactAccount(_ state: ProviderState) -> some View {
        let snapshot = QuotaPresentation(state: state)
        let metric = snapshot.metrics.first
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(state.manifest.fullName).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 5)
                if state.manifest.supportsQuota {
                    if let metric {
                        Text(metric.label).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                        Text(metric.value).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(snapshot.isOld ? Palette.muted : Palette.ink)
                    } else {
                        Text(snapshot.status).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    if snapshot.isOld {
                        Text("旧值").font(.system(size: 9.5)).foregroundStyle(Palette.warn)
                    }
                } else {
                    Text("仅 API").font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
            }
            if let percentage = metric?.percentage {
                ProgressLine(pct: percentage).opacity(snapshot.isOld ? 0.45 : 1)
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu { accountMenu(state) }
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
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border.opacity(0.8), lineWidth: 0.6))
        .contextMenu { accountMenu(state) }
    }
    @ViewBuilder private func accountMenu(_ state: ProviderState) -> some View {
        Button("打开账号") { SettingsWindowManager.shared.showAccount(state.slug) }
        Button("查询额度") { SettingsWindowManager.shared.modelForQuery()?.query(state.slug) }
            .disabled(queryUnavailable(state))
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
