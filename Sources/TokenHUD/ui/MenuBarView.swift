import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: DataEngine
    @ObservedObject var panelCtrl: PanelController
    @ObservedObject var model: SettingsModel
    var onOpenSettings: () -> Void
    var onTogglePanel: () -> Void
    var onRefresh: () -> Void
    var onOpenAccount: (String) -> Void

    private var accounts: [AccountRow] {
        model.allAccounts.filter { $0.enabled && !engine.floatingHiddenSlugs.contains($0.id) }
    }
    private var providerNames: [String] {
        var names: [String] = []
        for row in accounts {
            let name = model.providerName(for: row)
            if !names.contains(name) { names.append(name) }
        }
        return names
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 17) {
                    if accounts.isEmpty { emptyState }
                    ForEach(providerNames, id: \.self) { provider in
                        let rows = accounts.filter { model.providerName(for: $0) == provider }
                        VStack(alignment: .leading, spacing: 8) {
                            providerHeading(provider, rows: rows)
                            ForEach(rows) { row in accountCard(row) }
                        }
                    }
                    if engine.nodeMissing {
                        Label("未找到 Node.js，暂时无法查询", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5)).foregroundStyle(Palette.warn)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 440)
            if let toast = model.toast {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: toast.isError ? "exclamationmark.circle" : "checkmark.circle")
                    Text(toast.text).lineLimit(3)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(toast.isError ? Palette.danger : Palette.muted)
                .padding(.horizontal, 14).padding(.bottom, 10)
                .accessibilityElement(children: .combine)
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            footer
        }
        .frame(width: 420)
        .foregroundStyle(Palette.ink)
        .background(Palette.canvas)
    }
    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text("TokenHUD").font(.system(size: 14, weight: .semibold))
            Text("额度").font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Palette.accentSoft, in: Capsule())
            Spacer()
            if engine.isRefreshingAll {
                ProgressView().controlSize(.mini).frame(width: 26, height: 26)
                    .accessibilityLabel("正在刷新额度")
            } else {
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(QuickPanelIconStyle())
                    .accessibilityLabel("刷新所有可查询账号")
                    .help("仅查询额度，不发送模型调用")
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
    }
    private func providerHeading(_ provider: String, rows: [AccountRow]) -> some View {
        HStack(spacing: 6) {
            if let icon = rows.first?.plugin.manifest.icon {
                Image(systemName: icon).font(.system(size: 11)).accessibilityHidden(true)
            }
            Text(provider).font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
            Text("\(rows.count)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Palette.badgeBg, in: Capsule())
            Spacer()
        }
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 2)
    }
    private func accountCard(_ row: AccountRow) -> some View {
        let snapshot = QuotaPresentation(state: row.state)
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 8) {
                Button { onOpenAccount(row.id) } label: {
                    HStack(spacing: 7) {
                        Text(row.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开账号 \(row.name)")
                .help("打开账号配置")
                if model.running.contains(row.id) {
                    ProgressView().controlSize(.mini).frame(width: 22, height: 22)
                        .accessibilityLabel("正在查询 \(row.name)")
                } else if row.canQuery {
                    Button { model.query(row.id) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(QuickPanelIconStyle(size: 22))
                        .disabled(!model.quotaConfigured(row))
                        .accessibilityLabel("查询 \(row.name) 的额度")
                }
            }
            if row.canQuery {
                if snapshot.metrics.isEmpty {
                    Text(model.quotaConfigured(row) ? snapshot.status : "查询凭证待配置")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        .padding(.vertical, 3)
                } else {
                    QuotaMetricGrid(metrics: snapshot.metrics, old: snapshot.isOld, compact: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if snapshot.isOld {
                        Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                        Text(snapshot.status).lineLimit(2)
                    } else {
                        Text(snapshot.updated).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    if snapshot.isOld {
                        Text(snapshot.updated).foregroundStyle(Palette.muted).monospacedDigit()
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(snapshot.isOld ? Palette.warn : Palette.muted)
            } else {
                Text("仅 API 调用").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.border.opacity(0.8), lineWidth: 0.7))
        .contextMenu {
            Button("打开账号") { onOpenAccount(row.id) }
            Button("查询额度") { model.query(row.id) }.disabled(!row.canQuery || !model.quotaConfigured(row))
            Divider()
            Button(panelCtrl.isVisible ? "关闭悬浮速览" : "打开悬浮速览", action: onTogglePanel)
            Button("管理账号…", action: onOpenSettings)
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onOpenSettings) {
                Label("管理账号", systemImage: "slider.horizontal.3")
            }.buttonStyle(QuickPanelTextStyle())
            Spacer()
            Text("\(accounts.count) 个账号").font(.system(size: 11)).foregroundStyle(Palette.muted)
            Button(action: onTogglePanel) {
                Label(panelCtrl.isVisible ? "关闭悬浮" : "悬浮速览", systemImage: "rectangle.on.rectangle")
            }.buttonStyle(QuickPanelTextStyle())
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
    }
    private var emptyState: some View {
        VStack(alignment: .center, spacing: 9) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 23)).foregroundStyle(Palette.muted)
            Text("暂无显示中的账号").font(.system(size: 12.5, weight: .medium))
            Text("在账号管理中添加账号，或开启展示。")
                .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            Button("管理账号", action: onOpenSettings).barButton()
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

struct QuickPanelIconStyle: ButtonStyle {
    var size: CGFloat = 26
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Palette.muted)
            .frame(width: size, height: size)
            .background(configuration.isPressed ? Palette.badgeBg : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.35)
    }
}

struct QuickPanelTextStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(configuration.isPressed ? Palette.badgeBg : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
