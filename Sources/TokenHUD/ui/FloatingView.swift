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
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "circle.grid.2x2.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("TokenHUD").font(.caption.weight(.semibold))
                Spacer()
                Button(action: onToggle) { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .accessibilityLabel(expanded ? "收起悬浮明细" : "展开悬浮明细")
                    .help(expanded ? "收起明细" : "展开明细")
                Button { controller.hide() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("关闭悬浮速览").help("关闭悬浮速览")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onToggle)
            if expanded {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if states.isEmpty { Text("暂无显示中的账号").foregroundStyle(.secondary) }
                        ForEach(states) { state in floatingAccount(state) }
                    }.padding(12)
                }
                .frame(height: 290)
                Divider()
                HStack {
                    Button("管理账号…", action: onOpenSettings)
                    Spacer()
                    Button("刷新额度", action: onRefreshAll).disabled(engine.isRefreshingAll)
                }.buttonStyle(.borderless).font(.caption).padding(10)
            } else {
                HStack(spacing: 8) {
                    if let state = states.first {
                        let snapshot = QuotaPresentation(state: state)
                        Text(state.manifest.fullName).lineLimit(1)
                        Spacer(minLength: 4)
                        if state.manifest.supportsQuota {
                            Text(snapshot.metrics.first?.value ?? "—").monospacedDigit()
                            if snapshot.isOld { Text("旧值").foregroundStyle(.secondary) }
                        } else { Text("API").foregroundStyle(.secondary) }
                        if states.count > 1 { Text("+\(states.count - 1)").foregroundStyle(.secondary) }
                    } else { Text("暂无账号").foregroundStyle(.secondary) }
                }
                .font(.caption).padding(.horizontal, 12).padding(.bottom, 10)
                .contentShape(Rectangle()).onTapGesture(count: 2, perform: onToggle)
            }
        }
        .frame(width: 320)
        .foregroundStyle(.primary)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
                .opacity(reduceTransparency ? 1 : max(0.45, controller.bgOpacity))
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.15)))
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
    private func floatingAccount(_ state: ProviderState) -> some View {
        let snapshot = QuotaPresentation(state: state)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button { SettingsWindowManager.shared.showAccount(state.slug) } label: {
                    Text(state.manifest.fullName).font(.callout.weight(.medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("打开此账号")
                if state.manifest.supportsQuota,
                   let model = operationModel {
                    FloatingQueryAction(model: model, slug: state.slug, name: state.manifest.fullName)
                }
            }
            if state.manifest.supportsQuota {
                ForEach(snapshot.metrics) { metric in QuotaMetricView(metric: metric, old: snapshot.isOld, compact: true) }
                Text(snapshot.status).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("仅 API 调用").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("打开账号") { SettingsWindowManager.shared.showAccount(state.slug) }
            Button("查询额度") { SettingsWindowManager.shared.modelForQuery()?.query(state.slug) }
                .disabled(!state.manifest.supportsQuota)
            Divider()
            Button("关闭悬浮速览") { controller.hide() }
            Button("管理账号…", action: onOpenSettings)
        }
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
                ProgressView().controlSize(.mini).accessibilityLabel("正在查询 \(name)")
            } else {
                Button { model.query(slug) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.row(slug).map { !model.quotaConfigured($0) } ?? true)
                    .accessibilityLabel("查询 \(name) 的额度")
            }
        }
    }
}
