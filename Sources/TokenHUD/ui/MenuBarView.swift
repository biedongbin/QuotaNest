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
            HStack {
                Text("账号快览").font(.headline)
                Spacer()
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(engine.isRefreshingAll)
                    .accessibilityLabel("刷新所有可查询账号")
                    .help("仅查询额度，不发送模型调用")
            }.padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if accounts.isEmpty {
                        Text("暂无显示中的账号").foregroundStyle(.secondary).padding(.vertical, 18)
                    }
                    ForEach(providerNames, id: \.self) { provider in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(provider).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(accounts.filter { model.providerName(for: $0) == provider }) { row in
                                accountRow(row)
                            }
                        }
                    }
                    if engine.nodeMissing { Label("未找到 Node.js", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }.padding(14)
            }.frame(maxHeight: 430)
            if let toast = model.toast {
                Text(toast.text).font(.caption).foregroundStyle(toast.isError ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            Divider()
            HStack {
                Button("管理账号…", action: onOpenSettings)
                Spacer()
                Button(panelCtrl.isVisible ? "关闭悬浮" : "打开悬浮", action: onTogglePanel)
            }.padding(12)
        }
        .frame(width: 350)
    }
    private func accountRow(_ row: AccountRow) -> some View {
        let snapshot = QuotaPresentation(state: row.state)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button { onOpenAccount(row.id) } label: {
                    Text(row.name).font(.body.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("打开此账号")
                if model.running.contains(row.id) {
                    ProgressView().controlSize(.mini).accessibilityLabel("正在查询 \(row.name)")
                } else if row.canQuery {
                    Button { model.query(row.id) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(!model.quotaConfigured(row))
                        .accessibilityLabel("查询 \(row.name) 的额度")
                }
            }
            if row.canQuery {
                ForEach(snapshot.metrics) { metric in QuotaMetricView(metric: metric, old: snapshot.isOld, compact: true) }
                Text(snapshot.status + " · " + snapshot.updated).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("仅 API 调用 · 未启用额度查询").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("打开账号") { onOpenAccount(row.id) }
            Button("查询额度") { model.query(row.id) }.disabled(!row.canQuery || !model.quotaConfigured(row))
            Divider()
            Button(panelCtrl.isVisible ? "关闭悬浮速览" : "打开悬浮速览", action: onTogglePanel)
            Button("管理账号…", action: onOpenSettings)
        }
    }
}
