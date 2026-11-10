import SwiftUI

/// One snapshot contract is shared by the account window, menu and floating panel.
struct QuotaPresentation {
    let state: ProviderState?
    var isRefreshing = false
    var isOld: Bool {
        guard let state, let cache = state.cache else { return false }
        return state.isStale || cache.stale == true || cache.error != nil
    }
    var status: String {
        if isRefreshing {
            if let error = state?.cache?.error {
                return L10n.tr("正在重试；上次查询失败：%@", QuotaErrorPresentation.message(for: error))
            }
            return state?.cache?.generatedAt == nil ? L10n.tr("正在查询额度…") : L10n.tr("正在刷新，显示上次成功快照")
        }
        guard let cache = state?.cache else { return L10n.tr("尚未查询") }
        if let error = cache.error { return L10n.tr("查询失败：") + QuotaErrorPresentation.message(for: error) }
        return isOld ? L10n.tr("数据已过期") : L10n.tr("额度已更新")
    }
    var updated: String { formatCacheTime(state?.cache?.generatedAt) }
    var metrics: [QuotaMetric] {
        QuotaTabView.rows(from: state?.cache).enumerated().map { index, row in
            QuotaMetric(id: index, label: row.label, percentage: row.pct, amount: row.amount,
                        limit: row.limit, unit: row.unit, period: row.period, resetsAt: row.resetsAt, selectionKey: row.key)
        }
    }
}

struct QuotaMetric: Identifiable {
    let id: Int
    let label: String
    let percentage: Double?
    let amount: Double?
    let limit: Double?
    let unit: String?
    let period: String?
    let resetsAt: Int?
    var selectionKey: String = ""
    var isFiveHour: Bool {
        let value = (period ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        let name = label.lowercased().replacingOccurrences(of: " ", with: "")
        return ["five_hour", "5h", "5hours", "5_hour"].contains(value)
            || ["5小时", "5h", "5hours"].contains(name)
    }
    var resetDescription: String? {
        if let reset = formatResetAt(resetsAt) { return reset }
        return period == "balance" ? nil : L10n.tr("重置时间未知")
    }
    var value: String {
        if let percentage {
            return L10n.percent(percentage)
        }
        if let amount, let limit { return QuotaTabView.unitLabel(amount, limit, unit: unit) }
        if let amount { return "\(L10n.number(amount)) \(unit ?? "")" }
        if let limit { return L10n.tr("上限 %@ %@", String(describing: L10n.number(limit)), String(describing: unit ?? "")) }
        return "—"
    }
}

struct QuotaMetricGrid: View {
    let metrics: [QuotaMetric]
    var old = false
    var compact = false
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 18, alignment: .top),
              count: metrics.count == 1 ? 1 : 2)
    }
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: compact ? 14 : 22) {
            ForEach(metrics) { metric in
                QuotaMetricView(metric: metric, old: old, compact: compact)
            }
        }
    }
}

struct QuotaMetricView: View {
    let metric: QuotaMetric
    var old = false
    var compact = false
    private var meterColor: Color { (metric.percentage ?? 0) >= 90 ? Palette.warn : Palette.accent }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.label).foregroundStyle(Palette.muted).lineLimit(2)
                Spacer(minLength: 2)
                Text(metric.value).fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(old ? Palette.muted : Palette.ink)
                    .fixedSize(horizontal: metric.percentage != nil, vertical: metric.percentage == nil)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: metric.percentage == nil ? .infinity : nil, alignment: .trailing)
            }
            .font(.system(size: compact ? 11.5 : 13))
            if let percentage = metric.percentage {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.barTrack)
                        Capsule().fill(meterColor.opacity(old ? 0.4 : 1))
                            .frame(width: geometry.size.width * CGFloat(min(max(percentage, 0), 100) / 100))
                    }
                }
                .frame(height: 4)
                .accessibilityLabel(L10n.tr("%@已用", String(describing: metric.label)))
                .accessibilityValue(metric.value + (old ? L10n.tr("，旧值") : ""))
            }
            if !compact, metric.percentage != nil, let amount = metric.amount, let limit = metric.limit {
                Text(QuotaTabView.unitLabel(amount, limit, unit: metric.unit))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if old {
                    Text(L10n.tr("旧值")).foregroundStyle(Palette.warn)
                }
                if let reset = metric.resetDescription {
                    Text(reset).foregroundStyle(Palette.muted).lineLimit(2)
                }
            }
            .font(.system(size: compact ? 10.5 : 11.5))
            if !compact, let period = metric.period, period != "balance", period != metric.label {
                Text(period).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct QuotaTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow
    private var presentation: QuotaPresentation {
        QuotaPresentation(state: row.state, isRefreshing: model.running.contains(row.id) || model.engine.queryingSlugs.contains(row.id))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.tr("额度")).font(Typo.section).foregroundStyle(Palette.ink)
                    Text(L10n.tr("供应商返回的实际用量、余额与周期信息"))
                        .font(Typo.small).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 12)
                Button {
                    model.query(row.id)
                } label: {
                    Label(presentation.isRefreshing ? L10n.tr("查询中") : L10n.tr("刷新额度"), systemImage: "arrow.clockwise")
                }
                .barButton()
                .disabled(!row.canQuery || !model.quotaConfigured(row) || presentation.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
            }
            if !row.canQuery {
                CardBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L10n.tr("未启用额度查询"), systemImage: "chart.bar.xaxis")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                        Text(row.plugin.manifest.isSourceConfigurationReadOnly ? SettingsModel.sourceReadOnlyMessage : L10n.tr("需要时，在连接中配置额度接口；用量查询统一继承基础认证。模型测试与调用计划取决于供应商类型的接入能力。"))
                            .font(Typo.small).foregroundStyle(Palette.muted)
                        Button(L10n.tr("配置额度查询")) {
                            model.tab = .config
                            model.startEdit()
                        }.barButton().disabled(row.plugin.manifest.isSourceConfigurationReadOnly)
                    }
                }
            } else {
                CardBox {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 7) {
                            if presentation.isRefreshing {
                                ProgressView().controlSize(.mini)
                                Text(presentation.status).foregroundStyle(presentation.isOld ? Palette.warn : Palette.muted)
                            } else {
                                Circle().fill(presentation.isOld ? Palette.warn : Palette.accent)
                                    .frame(width: 5, height: 5).accessibilityHidden(true)
                                Text(presentation.status).foregroundStyle(presentation.isOld ? Palette.warn : Palette.muted)
                            }
                            Spacer(minLength: 8)
                            Text(presentation.updated).foregroundStyle(Palette.muted).monospacedDigit()
                        }
                        .font(.system(size: 11.5))
                        if let diagnostic = model.engine.queryDiagnostics[row.id] {
                            Text(L10n.tr("本次尝试 %@ 次，重试 %@ 次", String(describing: diagnostic.attemptCount), String(describing: diagnostic.retryCount)))
                                .font(Typo.small).foregroundStyle(Palette.muted)
                            if diagnostic.finalError != nil && !presentation.metrics.isEmpty {
                                Text(L10n.tr("本次查询未成功，下方保留上次成功的旧值，不代表当前额度。"))
                                    .font(Typo.small).foregroundStyle(Palette.warn)
                            }
                        }
                        Text(L10n.tr("已启用账号最长每 5 分钟查询一次；失败自动重试 2 次。"))
                            .font(Typo.small).foregroundStyle(Palette.muted)
                        if presentation.metrics.isEmpty {
                            Text(model.quotaConfigured(row) ? L10n.tr("查询后，这里会显示服务返回的额度窗口。") : L10n.tr("请先在连接中补全基础认证与用量查询配置。"))
                                .font(Typo.small).foregroundStyle(Palette.muted)
                                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        } else {
                            QuotaMetricGrid(metrics: presentation.metrics, old: presentation.isOld || !row.enabled)
                        }
                        if !row.enabled {
                            Text(L10n.tr("账号已停用。手动查询不会恢复调用计划。"))
                                .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
        }
    }
    static func rows(from cache: UsageCache?) -> [(label: String, pct: Double?, amount: Double?, limit: Double?, unit: String?, period: String?, resetsAt: Int?, key: String)] {
        guard let cache else { return [] }
        if let windows = cache.windows, !windows.isEmpty {
            return windows.compactMap { window in
                guard window.usedPercentage != nil || window.amount != nil || window.limit != nil else { return nil }
                return (window.displayLabel ?? L10n.tr("额度窗口"), window.usedPercentage, window.amount, window.limit, window.unit, window.period, window.resetsAt, window.menuBarSelectionKey)
            }
        }
        let legacy: [(String, String, Bucket?)] = [("five_hour", L10n.tr("5 小时"), cache.fiveHour),
            ("seven_day", L10n.tr("本周"), cache.sevenDay), ("monthly", L10n.tr("本月"), cache.monthly)]
        return legacy.compactMap { key, label, bucket in
            guard let bucket, let percentage = bucket.usedPercentage else { return nil }
            return (label, percentage, nil, nil, nil, nil, bucket.resetsAt, key)
        }
    }
    static func unitLabel(_ amount: Double, _ limit: Double, unit: String?) -> String {
        func value(_ number: Double) -> String { L10n.number(number, fractionLength: number.truncatingRemainder(dividingBy: 1) == 0 ? 0...0 : 2...2) }
        if unit?.uppercased() == "USD" { return "$\(value(amount)) / $\(value(limit))" }
        return "\(value(amount)) / \(value(limit))" + (unit.map { " \($0)" } ?? "")
    }
}

struct ResultBox: View {
    enum Kind { case ok, error, info, neutral }
    let kind: Kind
    let title: String
    let detail: String
    private var color: Color { kind == .error ? Palette.danger : (kind == .ok ? Palette.accent : Palette.muted) }
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
                if !detail.isEmpty { Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.muted) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
    private var symbol: String {
        switch kind { case .ok: return "checkmark.circle"; case .error: return "exclamationmark.circle"; case .info: return "arrow.triangle.2.circlepath"; case .neutral: return "info.circle" }
    }
}
struct ProgressLine: View {
    let pct: Double?
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.barTrack)
                if let pct {
                    Capsule().fill(pct >= 90 ? Palette.warn : Palette.accent)
                        .frame(width: geometry.size.width * CGFloat(min(max(pct, 0), 100) / 100))
                }
            }
        }
        .frame(height: 4)
        .accessibilityLabel(L10n.tr("已用额度")).accessibilityValue(pct.map { L10n.percent($0.rounded(), fractionLength: 0...0) } ?? L10n.tr("未知"))
    }
}
enum QuotaErrorPresentation {
    static func message(for code: String) -> String {
        switch code {
        case "network": return L10n.tr("无法连接服务")
        case "parse": return L10n.tr("服务返回的数据无法识别")
        case "no-subscription": return L10n.tr("当前额度池没有可用套餐，请检查导入的套餐类型")
        case "no-auth", "auth": return L10n.tr("请检查凭证或重新登录")
        case "ratelimit": return L10n.tr("查询频繁，请稍后重试")
        case "timeout", "busy": return L10n.tr("查询超时，请稍后重试")
        default: return code
        }
    }
}
