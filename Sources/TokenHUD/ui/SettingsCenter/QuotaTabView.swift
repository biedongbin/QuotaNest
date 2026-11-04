import SwiftUI

/// One snapshot contract is shared by the account window, menu and floating panel.
struct QuotaPresentation {
    let state: ProviderState?
    var isOld: Bool {
        guard let state else { return false }
        return state.isStale || state.cache?.stale == true || state.cache?.error != nil
    }
    var status: String {
        guard let cache = state?.cache else { return "尚未查询" }
        if let error = cache.error { return "查询失败：" + QuotaErrorPresentation.message(for: error) }
        return isOld ? "数据已过期" : "额度已更新"
    }
    var updated: String { formatCacheTime(state?.cache?.generatedAt) }
    var metrics: [QuotaMetric] {
        QuotaTabView.rows(from: state?.cache).enumerated().map { index, row in
            QuotaMetric(id: index, label: row.label, percentage: row.pct, amount: row.amount,
                        limit: row.limit, unit: row.unit, period: row.period, resetsAt: row.resetsAt)
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
    var resetDescription: String? {
        if let reset = formatResetAt(resetsAt) { return reset }
        return period == "balance" ? nil : "重置时间未知"
    }
    var value: String {
        if let percentage {
            return percentage.formatted(.number.precision(.fractionLength(0...1))) + "%"
        }
        if let amount, let limit { return QuotaTabView.unitLabel(amount, limit, unit: unit) }
        if let amount { return "\(amount.formatted()) \(unit ?? "")" }
        if let limit { return "上限 \(limit.formatted()) \(unit ?? "")" }
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
                .accessibilityLabel("\(metric.label)已用")
                .accessibilityValue(metric.value + (old ? "，旧值" : ""))
            }
            if !compact, metric.percentage != nil, let amount = metric.amount, let limit = metric.limit {
                Text(QuotaTabView.unitLabel(amount, limit, unit: metric.unit))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if old {
                    Text("旧值").foregroundStyle(Palette.warn)
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
    private var presentation: QuotaPresentation { QuotaPresentation(state: row.state) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("额度").font(Typo.section).foregroundStyle(Palette.ink)
                    Text("供应商返回的实际用量、余额与周期信息")
                        .font(Typo.small).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 12)
                Button {
                    model.query(row.id)
                } label: {
                    Label(model.running.contains(row.id) ? "查询中" : "刷新额度", systemImage: "arrow.clockwise")
                }
                .barButton()
                .disabled(!row.canQuery || !model.quotaConfigured(row) || model.running.contains(row.id))
                .keyboardShortcut("r", modifiers: .command)
            }
            if !row.canQuery {
                CardBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("未启用额度查询", systemImage: "chart.bar.xaxis")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                        Text(row.plugin.manifest.isSourceConfigurationReadOnly ? SettingsModel.sourceReadOnlyMessage : "需要时，在连接中配置额度接口；用量查询统一继承基础认证。模型测试与调用计划取决于供应商类型的接入能力。")
                            .font(Typo.small).foregroundStyle(Palette.muted)
                        Button("配置额度查询") {
                            model.tab = .config
                            model.startEdit()
                        }.barButton().disabled(row.plugin.manifest.isSourceConfigurationReadOnly)
                    }
                }
            } else {
                CardBox {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 7) {
                            if model.running.contains(row.id) {
                                ProgressView().controlSize(.mini)
                                Text("正在查询").foregroundStyle(Palette.muted)
                            } else {
                                Circle().fill(presentation.isOld ? Palette.warn : Palette.accent)
                                    .frame(width: 5, height: 5).accessibilityHidden(true)
                                Text(presentation.status).foregroundStyle(presentation.isOld ? Palette.warn : Palette.muted)
                            }
                            Spacer(minLength: 8)
                            Text(presentation.updated).foregroundStyle(Palette.muted).monospacedDigit()
                        }
                        .font(.system(size: 11.5))
                        if presentation.metrics.isEmpty {
                            Text(model.quotaConfigured(row) ? "查询后，这里会显示服务返回的额度窗口。" : "请先在连接中补全基础认证与用量查询配置。")
                                .font(Typo.small).foregroundStyle(Palette.muted)
                                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        } else {
                            QuotaMetricGrid(metrics: presentation.metrics, old: presentation.isOld || !row.enabled)
                        }
                        if !row.enabled {
                            Text("账号已停用。手动查询不会恢复调用计划。")
                                .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
        }
    }
    static func rows(from cache: UsageCache?) -> [(label: String, pct: Double?, amount: Double?, limit: Double?, unit: String?, period: String?, resetsAt: Int?)] {
        guard let cache else { return [] }
        if let windows = cache.windows, !windows.isEmpty {
            return windows.compactMap { window in
                guard window.usedPercentage != nil || window.amount != nil || window.limit != nil else { return nil }
                return (window.label ?? "额度窗口", window.usedPercentage, window.amount, window.limit, window.unit, window.period, window.resetsAt)
            }
        }
        let legacy: [(String, Bucket?)] = [("5 小时", cache.fiveHour), ("本周", cache.sevenDay), ("本月", cache.monthly)]
        return legacy.compactMap { label, bucket in
            guard let bucket, let percentage = bucket.usedPercentage else { return nil }
            return (label, percentage, nil, nil, nil, nil, bucket.resetsAt)
        }
    }
    static func unitLabel(_ amount: Double, _ limit: Double, unit: String?) -> String {
        func value(_ number: Double) -> String { String(format: number.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", number) }
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
        .accessibilityLabel("已用额度").accessibilityValue(pct.map { "\(Int($0.rounded()))%" } ?? "未知")
    }
}
enum QuotaErrorPresentation {
    static func message(for code: String) -> String {
        switch code {
        case "network": return "无法连接服务"
        case "parse": return "服务返回的数据无法识别"
        case "no-auth", "auth": return "请检查凭证或重新登录"
        case "ratelimit": return "查询频繁，请稍后重试"
        case "timeout", "busy": return "查询超时，请稍后重试"
        default: return "暂时无法取得额度"
        }
    }
}
