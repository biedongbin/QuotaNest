import SwiftUI

// MARK: - v0.2 菜单栏下拉 (AIUsage menu_bar 式): 顶部更新时间+刷新 / 按供应商分组账号条 / 底部主操作

struct MenuBarView: View {
    @ObservedObject var engine: DataEngine
    @ObservedObject var panelCtrl: PanelController
    var onOpenSettings: () -> Void
    var onTogglePanel: () -> Void
    var onRefresh: () -> Void
    /// 点单条 → 查询该账号 (设置中心模型动作; 菜单栏持引用由 StatusItemController 注入)
    var onQueryAccount: (String) -> Void = { _ in }

    /// 可见账号: 已停用 (disabled) 与 关闭悬浮窗显示 的都不出现
    private var visibleStates: [ProviderState] {
        engine.states.filter { st in
            !engine.disabledSlugs.contains(st.slug) && !engine.floatingHiddenSlugs.contains(st.slug)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleStates) { st in
                        providerSection(st)
                    }
                    if visibleStates.isEmpty {
                        Text("暂无显示中的账号").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                    notices
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 420)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            footer
        }
        .frame(width: 320)
    }

    // 顶部: 最近更新时间 + 刷新余额
    private var header: some View {
        HStack(spacing: 8) {
            Text("最近更新 \(engine.lastRefresh.map { Self.time($0) } ?? "—")")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                onRefresh()
            } label: {
                HStack(spacing: 4) {
                    if engine.isRefreshingAll {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    Text("刷新余额").font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .disabled(engine.isRefreshingAll)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // 底部: 悬浮窗开关 / 设置 / 退出
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                onTogglePanel()
            } label: {
                Label(panelCtrl.isVisible ? "关闭悬浮窗" : "打开悬浮窗",
                      systemImage: panelCtrl.isVisible ? "rectangle.on.rectangle" : "rectangle")
            }
            Button {
                onOpenSettings()
            } label: {
                Label("打开设置中心", systemImage: "slider.horizontal.3")
            }
            Divider()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var notices: some View {
        if !engine.registryErrors.isEmpty {
            ForEach(engine.registryErrors.sorted(by: { $0.key < $1.key }), id: \.key) { slug, msg in
                Text("\(slug): \(msg)").font(.caption2).foregroundStyle(.orange)
            }
        }
        if engine.nodeMissing {
            Text("node 未找到 — 设置中心内手动指定").font(.caption2).foregroundStyle(.orange)
        }
    }

    /// 单供应商组: 组头 (徽标+名+计数) + 每账号条目 (名+各窗口迷你进度; 点条目查询该账号)
    private func providerSection(_ st: ProviderState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                ProviderBadge(icon: st.manifest.icon, label: st.manifest.label,
                              accent: brandColor(st.manifest.accent), size: 22)
                Text(st.manifest.fullName)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                Spacer()
                if st.cache?.error == "auth" {
                    Text("需登录").foregroundStyle(.yellow).font(.caption2)
                } else {
                    PctText(pct: st.worstPct, size: 15, weight: .bold)
                }
            }
            // 单账号一供应商: 条目即窗口行 (点击查询)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(windowPairs(st), id: \.0) { label, w in
                    miniRow(label: label, pct: w.usedPercentage, resetsAt: w.resetsAt)
                }
                if windowPairs(st).isEmpty {
                    Text(st.cache?.error != nil
                         ? "查询失败：\(DataEngine.reason(for: st.cache?.error ?? ""))" : "暂无窗口数据")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 30)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { onQueryAccount(st.slug) }
        }
        .padding(.vertical, 2)
    }

    /// 迷你窗口行: 标签 + 短条 + % (AIUsage 式堆叠)
    private func miniRow(label: String, pct: Double?, resetsAt: Int?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            UsageBar(pct: pct)
                .frame(maxWidth: .infinity)
                .frame(height: 5)
            PctText(pct: pct, size: 11, weight: .semibold)
                .frame(width: 34, alignment: .trailing)
            if let cd = HUDFmt.resetCountdown(resetsAt, now: Date()) {
                CountdownChip(text: cd)
            } else {
                Text(" ").font(.caption2)   // 占位对齐
            }
        }
    }

    /// P1-11 窗口数据源: windows 优先, 旧三桶投影回落 (与 QuotaTabView.rows 同口径的轻量版)
    private func windowPairs(_ st: ProviderState) -> [(String, WindowBucket)] {
        if let wins = st.cache?.windows, !wins.isEmpty {
            return wins.compactMap { w in
                guard w.usedPercentage != nil || w.amount != nil || w.limit != nil else { return nil }
                return (w.label ?? "窗口", w)
            }
        }
        var out: [(String, WindowBucket)] = []
        if let b = st.cache?.fiveHour {
            out.append((st.manifest.buckets["five_hour"] ?? "5小时",
                        WindowBucket(label: nil, usedPercentage: b.usedPercentage, resetsAt: b.resetsAt)))
        }
        if let b = st.cache?.sevenDay {
            out.append((st.manifest.buckets["seven_day"] ?? "本周",
                        WindowBucket(label: nil, usedPercentage: b.usedPercentage, resetsAt: b.resetsAt)))
        }
        if let b = st.cache?.monthly {
            out.append((st.manifest.buckets["monthly"] ?? "本月",
                        WindowBucket(label: nil, usedPercentage: b.usedPercentage, resetsAt: b.resetsAt)))
        }
        return out
    }

    private static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
