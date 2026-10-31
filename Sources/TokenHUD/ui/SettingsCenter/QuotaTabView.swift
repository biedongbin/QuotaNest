import SwiftUI

/// The same snapshot semantics power the main window, menu and floating panel.
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
    var value: String {
        if let percentage { return "\(Int(percentage.rounded()))%" }
        if let amount, let limit { return QuotaTabView.unitLabel(amount, limit, unit: unit) }
        if let amount { return "\(amount.formatted()) \(unit ?? "")" }
        if let limit { return "上限 \(limit.formatted()) \(unit ?? "")" }
        return "—"
    }
}

struct QuotaMetricView: View {
    let metric: QuotaMetric
    var old = false
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.label).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Text(metric.value).monospacedDigit().fontWeight(.medium)
                if old { Text("旧值").font(.caption).foregroundStyle(.secondary) }
            }
            if !old, let percentage = metric.percentage {
                ProgressView(value: min(max(percentage, 0), 100), total: 100)
                    .tint(percentage >= 90 ? .orange : .accentColor)
                    .accessibilityLabel("\(metric.label)已用")
                    .accessibilityValue(metric.value)
            }
            if !compact {
                if metric.percentage != nil, let amount = metric.amount, let limit = metric.limit {
                    Text(QuotaTabView.unitLabel(amount, limit, unit: metric.unit)).foregroundStyle(.secondary)
                }
                if let reset = formatResetAt(metric.resetsAt) {
                    Text(reset).font(.caption).foregroundStyle(.secondary)
                } else if let period = metric.period {
                    Text(period).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(compact ? .caption : .body)
        .accessibilityElement(children: .combine)
    }
}

struct QuotaTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow
    private var presentation: QuotaPresentation { QuotaPresentation(state: row.state) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("额度查询").font(.headline)
                    Text("仅查询额度，不发送模型调用。").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.running.contains(row.id) ? "查询中…" : "查询额度", systemImage: "arrow.clockwise") { model.query(row.id) }
                    .disabled(!row.canQuery || !model.quotaConfigured(row) || model.running.contains(row.id))
                    .keyboardShortcut("r", modifiers: .command)
            }
            if !row.canQuery {
                ContentUnavailableView("未启用额度查询", systemImage: "chart.bar.xaxis",
                                       description: Text("此账号可独立用于 API 调用。需要时可在连接配置中添加额度查询。"))
            } else {
                ResultBox(kind: model.running.contains(row.id) ? .info : (presentation.isOld ? .neutral : .ok),
                          title: model.running.contains(row.id) ? "正在查询…" : presentation.status,
                          detail: "最近成功查询：\(presentation.updated)" + (row.enabled ? "" : " · 账号已停用，手动查询不会恢复计划"))
                if presentation.metrics.isEmpty {
                    Text(model.quotaConfigured(row) ? "查询成功后显示服务实际返回的额度窗口。" : "额度查询尚未配置完整，请检查连接配置。")
                        .foregroundStyle(.secondary).padding(.vertical, 20)
                }
                ForEach(presentation.metrics) { metric in
                    CardBox { QuotaMetricView(metric: metric, old: presentation.isOld || !row.enabled) }
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
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
        } icon: { Image(systemName: symbol).foregroundStyle(kind == .error ? Color.red : Color.secondary) }
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
        ProgressView(value: min(max(pct ?? 0, 0), 100), total: 100)
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
