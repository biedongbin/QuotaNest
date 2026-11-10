import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: DataEngine
    @ObservedObject var panelCtrl: PanelController
    @ObservedObject var model: SettingsModel
    var onOpenSettings: () -> Void
    var onTogglePanel: () -> Void
    var onRefresh: () -> Void
    var onOpenAccount: (String) -> Void
    @State private var visibleWindowFeedback: [String: Date] = [:]

    private var accounts: [AccountRow] {
        model.allAccounts.filter { $0.enabled && !engine.floatingHiddenSlugs.contains($0.id) }
    }
    private var refreshing: Bool { engine.isRefreshingAll || !engine.queryingSlugs.isEmpty }
    // A definite viewport prevents NSPopover from compressing the scroll view to its minimum size.
    private var viewportHeight: CGFloat { accounts.isEmpty ? 190 : min(440, CGFloat(accounts.count) * 112 + 14) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if accounts.isEmpty { emptyState }
                    ForEach(accounts) { row in accountCard(row) }
                    if engine.nodeMissing {
                        Label(L10n.tr("未找到 Node.js，暂时无法查询"), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5)).foregroundStyle(Palette.warn)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 16)
            }
            .frame(height: viewportHeight)
            if let toast = model.toast {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: toast.isError ? "exclamationmark.circle" : "checkmark.circle")
                    Text(toast.text).lineLimit(3)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(toast.isError ? Palette.danger : Palette.inkSecondary)
                .padding(.horizontal, 18).padding(.bottom, 10)
                .accessibilityElement(children: .combine)
            }
            QuickPanelTips()
            footer
        }
        .appLanguageEnvironment()
        .frame(width: 420)
        .foregroundStyle(Palette.ink)
        .background(Palette.canvas)
        .contextMenu {
            Button(L10n.tr("刷新可查询账号"), action: onRefresh)
            Button(panelCtrl.isVisible ? L10n.tr("关闭悬浮速览") : L10n.tr("打开悬浮速览"), action: onTogglePanel)
            Button(L10n.tr("管理账号…"), action: onOpenSettings)
            Divider()
            Button(L10n.tr("退出 %@", AppBrand.name)) { NSApplication.shared.terminate(nil) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: StatusItemController.menuBarLogo)
                .renderingMode(.template).foregroundStyle(Palette.accent)
                .frame(width: 20, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppBrand.name).font(.system(size: 14, weight: .semibold))
                Text(L10n.tr("额度速览")).font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Button(action: onRefresh) {
                HStack(spacing: 5) {
                    if refreshing { ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 12, height: 12) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)) }
                    Text(L10n.tr(refreshing ? "查询中" : "刷新额度"))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 10).frame(height: 27)
                .background(Palette.accentSoft, in: Capsule())
            }
            .buttonStyle(.plain).disabled(refreshing)
            .help(L10n.tr("仅查询额度，不发送模型调用"))
            Button(action: onOpenSettings) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(QuickPanelIconStyle(size: 28))
                .accessibilityLabel(L10n.tr("管理账号"))
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 13)
    }

    private func accountCard(_ row: AccountRow) -> some View {
        let snapshot = QuotaPresentation(state: row.state,
            isRefreshing: model.running.contains(row.id) || engine.queryingSlugs.contains(row.id))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { onOpenAccount(row.id) } label: {
                    HStack(spacing: 10) {
                        ProviderLogo(manifest: row.plugin.manifest, slug: row.id, size: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            HStack(spacing: 5) {
                                Text(model.providerName(for: row))
                                Circle().frame(width: 2, height: 2)
                                Text(AccountSourceFilter.origin(of: row.plugin.manifest).label)
                            }
                            .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("打开账号 %@", row.name))
                .help(L10n.tr("打开账号配置"))
                if row.canQuery {
                    statusLine(snapshot).frame(maxWidth: 150, alignment: .trailing)
                }
                if snapshot.isRefreshing {
                    ProgressView().controlSize(.mini).frame(width: 22, height: 22)
                        .accessibilityLabel(L10n.tr("正在查询 %@", row.name))
                } else if row.canQuery {
                    Button { model.query(row.id) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(QuickPanelIconStyle(size: 22))
                        .disabled(!model.quotaConfigured(row))
                        .accessibilityLabel(L10n.tr("查询 %@ 的额度", row.name))
                        .help(L10n.tr("查询额度/余额，不发送模型调用"))
                }
            }
            if row.canQuery {
                if snapshot.metrics.isEmpty {
                    Text(model.quotaConfigured(row) ? snapshot.status : L10n.tr("查询凭证待配置"))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                        ForEach(snapshot.metrics) { metric in compactMetric(metric, old: snapshot.isOld, row: row) }
                    }
                }
            } else {
                Label(L10n.tr("仅 API 调用"), systemImage: "arrow.up.right")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .frame(minHeight: 28)
            }
            if let result = model.windowCallResult(for: row.id), visibleWindowFeedback[row.id] == result.date {
                Text(result.phase == .success ? L10n.tr("调用成功；是否开启 5h 窗口以供应商额度为准") : result.message)
                    .font(.system(size: 10)).foregroundStyle(result.isError ? Palette.warn : Palette.muted)
                    .lineLimit(3).help(result.message + " · " + result.model)
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpenAccount(row.id) }
        .help(L10n.tr("双击打开账号详情"))
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .strokeBorder(engine.menuBarProviderSlug == row.id ? Palette.accent.opacity(0.35) : Palette.border.opacity(0.65),
                          lineWidth: engine.menuBarProviderSlug == row.id ? 1.2 : 0.6))
        .task(id: model.windowCallResult(for: row.id)?.date) {
            guard let result = model.windowCallResult(for: row.id), result.feedbackIsVisible() else {
                visibleWindowFeedback.removeValue(forKey: row.id); return
            }
            visibleWindowFeedback[row.id] = result.date
            guard let expiry = result.feedbackExpiresAt else { return }
            let delay = max(0, expiry.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !Task.isCancelled, visibleWindowFeedback[row.id] == result.date {
                visibleWindowFeedback.removeValue(forKey: row.id)
            }
        }
        .contextMenu {
            Button(L10n.tr("打开账号")) { onOpenAccount(row.id) }
            Button(L10n.tr("查询额度")) { model.query(row.id) }.disabled(!row.canQuery || !model.quotaConfigured(row))
            if row.plugin.manifest.windowTrigger != nil {
                Button(L10n.tr("尝试开启 5h 窗口")) { model.triggerWindow(row.id) }
                    .disabled(!model.windowCallConfigured(row) || model.callRunning.contains(row.id))
            }
            Divider()
            Button(panelCtrl.isVisible ? L10n.tr("关闭悬浮速览") : L10n.tr("打开悬浮速览"), action: onTogglePanel)
            Button(L10n.tr("管理账号…"), action: onOpenSettings)
            Divider()
            Button(L10n.tr("退出 %@", AppBrand.name)) { NSApplication.shared.terminate(nil) }
        }
    }

    private func compactMetric(_ metric: QuotaMetric, old: Bool, row: AccountRow) -> some View {
        HStack(spacing: 5) {
            if let percentage = metric.percentage {
                let selected = engine.menuBarProviderSlug == row.id && engine.menuBarMetric?.selectionKey == metric.selectionKey
                Button {
                    if !engine.setIconMetric(provider: row.id, key: metric.selectionKey) {
                        model.flash(L10n.tr("所选额度周期暂不可用"), error: true)
                    }
                } label: {
                    QuickQuotaRing(percentage: percentage, old: old, size: 32)
                        .overlay {
                            Text(metric.value).font(.system(size: 8.5, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(old ? Palette.muted : Palette.ink)
                        }
                        .padding(2)
                        .background(selected ? Palette.accentSoft.opacity(0.6) : .clear, in: Circle())
                        .overlay(Circle().strokeBorder(selected ? Palette.accent.opacity(0.65) : Palette.surface, lineWidth: selected ? 1.3 : 0.7))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("quick-panel.menu-metric." + row.id + "." + metric.selectionKey)
                .accessibilityLabel(L10n.tr("将 %@ 的 %@ 显示到菜单栏", row.name, metric.label))
                .accessibilityValue(metric.value + (selected ? " · " + L10n.tr("已显示在菜单栏") : ""))
                .help(L10n.tr("点击圆环，将 %@ 的 %@ 显示到菜单栏", row.name, metric.label))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(metric.label).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                    windowButton(metric, row: row)
                }
                if metric.percentage == nil {
                    Text(metric.value).font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(2)
                }
                if let countdown = HUDFmt.resetCountdown(metric.resetsAt, now: Date()) {
                    Text(L10n.tr("%@ 后重置", countdown))
                        .font(.system(size: 9)).foregroundStyle(Palette.muted).monospacedDigit().lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else if let reset = metric.resetDescription {
                    Text(reset).font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .help(metric.resetDescription ?? metric.label)
    }

    @ViewBuilder private func windowButton(_ metric: QuotaMetric, row: AccountRow) -> some View {
        if metric.isFiveHour, let trigger = row.plugin.manifest.windowTrigger, trigger.period == "five_hour" {
            Button { model.triggerWindow(row.id) } label: {
                if model.callRunning.contains(row.id) {
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise.circle").font(.system(size: 12)).frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.plain).foregroundStyle(Palette.accent)
            .disabled(!model.windowCallConfigured(row) || model.callRunning.contains(row.id))
            .accessibilityIdentifier("quick-panel.window." + row.id)
            .accessibilityLabel(L10n.tr("尝试开启 5h 窗口"))
            .help(L10n.tr("发送 1 次模型调用，会消耗额度；尝试开启 5h 窗口，不保证开窗或重置。模型：%@", model.scheduleModel(row)))
        }
    }

    private func statusLine(_ snapshot: QuotaPresentation) -> some View {
        HStack(spacing: 5) {
            Circle().fill(snapshot.isOld ? Palette.warn : (snapshot.metrics.isEmpty ? Palette.muted : Palette.ok)).frame(width: 4, height: 4)
            Text(snapshot.isOld || snapshot.isRefreshing || snapshot.metrics.isEmpty
                 ? snapshot.status : L10n.tr("更新于 %@", snapshot.updated))
                .lineLimit(1)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(snapshot.isOld ? Palette.warn : Palette.muted)
        .help(snapshot.status + " · " + snapshot.updated)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("%@ 个账号", String(accounts.count)))
                .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            Spacer()
            Button(action: onTogglePanel) {
                Label(panelCtrl.isVisible ? L10n.tr("关闭悬浮") : L10n.tr("悬浮速览"), systemImage: "rectangle.on.rectangle")
            }.buttonStyle(QuickPanelTextStyle())
            Rectangle().fill(Palette.border).frame(width: 1, height: 12)
            Button(action: onOpenSettings) { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(QuickPanelIconStyle(size: 25)).accessibilityLabel(L10n.tr("管理账号"))
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border.opacity(0.7)).frame(height: 0.5) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(nsImage: StatusItemController.menuBarLogo).renderingMode(.template)
                .foregroundStyle(Palette.accent).frame(height: 28)
            Text(L10n.tr("暂无显示中的账号")).font(.system(size: 13, weight: .medium))
            Text(L10n.tr("在账号管理中添加账号，或开启展示。"))
                .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            Button(L10n.tr("管理账号"), action: onOpenSettings).barButton()
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
    }
}

private struct QuickPanelTips: View {
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tips = [
        "设置定时计划，自动尝试开启 5h 窗口",
        "支持一键导入 CPA、9Router、Magpie、CC-Switch",
        "点击额度圆环，选择菜单栏显示的周期",
        "在设置中切换悬浮窗样式"
    ]
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "lightbulb").font(.system(size: 10)).accessibilityHidden(true)
            ZStack(alignment: .leading) {
                Text(L10n.tr(tips[index])).font(.system(size: 10.5))
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .id(index).transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Palette.muted)
        .frame(height: 22).padding(.horizontal, 18).padding(.vertical, 5)
        .help(L10n.tr(tips[index]))
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.35)) {
                    index = (index + 1) % tips.count
                }
            }
        }
    }
}

private struct QuickQuotaRing: View {
    let percentage: Double
    var old = false
    var size: CGFloat = 43
    static func tint(_ percentage: Double) -> Color { percentage >= 90 ? Palette.warn : Palette.accent }
    var body: some View {
        ZStack {
            Circle().stroke(Palette.barTrack, lineWidth: 3)
            Circle().trim(from: 0, to: min(max(percentage, 0), 100) / 100)
                .stroke(Self.tint(percentage).opacity(old ? 0.35 : 1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(2).frame(width: size, height: size)
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
        configuration.label.font(.system(size: 11))
            .foregroundStyle(Palette.inkSecondary)
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(configuration.isPressed ? Palette.badgeBg : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
