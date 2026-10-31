import SwiftUI

// MARK: - 额度 tab

struct QuotaTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow

    /// P1-8 四态: 额度查询能力判定 (集中 CapabilityStatus.quota)
    private var quotaStatus: CapabilityStatus { .quota(manifest: row.plugin.manifest) }

    /// 四态对应说明文案 (未接入 ≠ 服务不支持, 不冒充断言)
    private var quotaStatusText: String {
        switch quotaStatus {
        case .configured: return ""
        case .notIntegrated:
            return "\(row.plugin.manifest.fullName) 的额度解析 App 尚未接入，因此不显示 5 小时 / 本周 / 本月数值。"
        case .notSupported:
            return "\(row.plugin.manifest.fullName) 的服务端不提供额度查询，因此不显示数值。"
        case .notConfigured:
            return "额度查询端点未配置，补齐后可查询。"
        case .unverified:
            return "该账号额度查询能力待核实。"
        }
    }

    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("额度").font(Typo.section).foregroundStyle(Palette.ink)
                        Text("最近查询：\(lastTimeText)").font(Typo.small).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                }
                .padding(.bottom, 12)

                if model.running.contains(row.id) {
                    ResultBox(kind: .info, title: "查询中…",
                              detail: "已向 \(row.plugin.manifest.fullName) 发起额度查询，窗口保持可操作。")
                } else {
                    ResultBox(kind: resultKind, title: resultTitle, detail: resultDetail)
                }

                if quotaStatus != .configured {
                    Text(quotaStatusText)
                        .font(Typo.small).foregroundStyle(Palette.muted)
                        .padding(.top, 12)
                } else if !quotaRows.isEmpty {
                    quotaGrid.padding(.top, 16)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.state?.cache?.error == nil ? "尚未取得额度" : "暂时无法取得额度")
                            .font(Typo.body).foregroundStyle(Palette.ink)
                        Text(row.isConfigured ? "查询成功后，这里只显示服务返回的实际窗口。" : "请先在配置页补全凭证，再查询额度。")
                            .font(Typo.small).foregroundStyle(Palette.muted)
                        if !row.isConfigured {
                            Button("前往配置") { _ = model.selectAccount(row.id, tab: .config) }.barButton()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
                }
            }
        }
    }

    // MARK: 结果条

    private var lastTimeText: String {
        if model.running.contains(row.id) { return "进行中" }
        guard let c = row.state?.cache, let g = c.generatedAt else { return "尚未查询" }
        return formatCacheTime(g)
    }

    private var resultKind: ResultBox.Kind {
        guard row.enabled, let c = row.state?.cache else { return .neutral }
        return c.error != nil ? .error : .ok
    }

    private var resultTitle: String {
        if !row.enabled { return "账号已停用" }
        guard let c = row.state?.cache else { return "尚未查询" }
        if c.error != nil { return "查询失败" }
        if c.stale == true { return "最近查询（缓存已过期）" }
        return "最近查询成功"
    }

    private var resultDetail: String {
        if !row.enabled {
            let last = row.state?.cache?.generatedAt.map { "上次查询：\(formatCacheTime($0))。" } ?? ""
            return "后台查询和定时调用已暂停。\(last)仍可手动查询，查询不会启用后台任务。"
        }
        guard let c = row.state?.cache else {
            return row.canQuery ? "点击「查询额度」后在这里显示该账号的额度与重置时间。"
                                : "该账号额度查询\(quotaStatus == .notIntegrated ? "未接入" : "不可用")。"
        }
        var parts: [String] = [formatCacheTime(c.generatedAt)]
        if let run = model.lastRun[row.id] {
            parts.append("耗时 \(run.ms) ms")
        }
        if let error = c.error {
            parts.append(QuotaErrorPresentation.message(for: error))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 三卡

    /// 缓存里带错误或已被标旧值: 数值只能当"旧值"看, 不能冒充当前额度
    private var isOldValue: Bool {
        guard let c = row.state?.cache else { return false }
        return !row.enabled || c.error != nil || c.stale == true
    }

    /// P1-11 UI 数据源切换 (纯函数): windows 非空 → 窗口行; 空 → 旧三卡回落
    /// 行 = (label, usedPct, amount, limit, unit, period, resetsAt)
    static func rows(from cache: UsageCache?) -> [(label: String, pct: Double?, amount: Double?,
                                                   limit: Double?, unit: String?,
                                                   period: String?, resetsAt: Int?)] {
        guard let cache else { return [] }
        if let wins = cache.windows, !wins.isEmpty {
            return wins.compactMap { w in
                // 无任何量化信息的窗口行不渲染 (label-only 视为噪声)
                guard w.usedPercentage != nil || w.amount != nil || w.limit != nil else { return nil }
                return (w.label ?? "窗口", w.usedPercentage, w.amount, w.limit, w.unit, w.period, w.resetsAt)
            }
        }
        // 旧缓存仅展示实际量化的窗口；错误缓存不生成三张空卡。
        let legacy: [(String, Bucket?)] = [("5 小时", cache.fiveHour), ("本周", cache.sevenDay), ("本月", cache.monthly)]
        return legacy.compactMap { label, bucket in
            guard let bucket, let percentage = bucket.usedPercentage else { return nil }
            return (label, percentage, nil, nil, nil, nil, bucket.resetsAt)
        }
    }

    private var quotaRows: [(label: String, pct: Double?, amount: Double?,
                             limit: Double?, unit: String?, period: String?, resetsAt: Int?)] {
        Self.rows(from: row.state?.cache)
    }

    private var quotaGrid: some View {
        EqualWidthWindowLayout { quotaCards }
    }

    private var quotaCards: some View {
        ForEach(quotaRows.indices, id: \.self) { i in
            let r = quotaRows[i]
            quotaCard(r.label, pct: r.pct, amount: r.amount, limit: r.limit,
                      unit: r.unit, period: r.period, resetsAt: r.resetsAt)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func quotaCard(_ label: String, pct: Double?, amount: Double?, limit: Double?,
                           unit: String?, period: String?, resetsAt: Int?) -> some View {
        let old = isOldValue
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).font(Typo.small).foregroundStyle(old ? Palette.muted.opacity(0.9) : Palette.muted)
                Spacer()
                if let p = pct {
                    Text("\(Int(p.rounded()))%").font(Typo.small)
                        .foregroundStyle(old ? Palette.muted.opacity(0.75) : Palette.muted)
                }
            }
            if let p = pct {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(p.rounded()))%")
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(old ? Palette.muted : Palette.ink)
                    if old {
                        // 来源标识: 这个数是缓存里的旧值, 不代表现在用了这么多
                        Text("旧值").font(Typo.small)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Palette.badgeBg))
                            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .padding(.top, 6)
                // amount/limit 有则展示 "$x/$y" (unit USD) 或 "x/y <unit>"
                if let a = amount, let l = limit {
                    Text(Self.unitLabel(a, l, unit: unit))
                        .font(Typo.small).foregroundStyle(old ? Palette.muted.opacity(0.75) : Palette.muted)
                        .padding(.top, 4)
                }
                if old {
                    // 错误态不画进度条: 满/空都会被读成"当前用量"
                    Text(oldValueNote)
                        .font(Typo.small).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                } else {
                    ProgressLine(pct: p)
                        .padding(.top, 10)
                    Text(resetLine(resetsAt, period: period))
                        .font(Typo.small).foregroundStyle(Palette.muted)
                        .padding(.top, 6)
                }
            } else {
                Text("—")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 6)
                Text(old || row.state?.cache == nil ? "尚未查询到有效额度" : "此窗口额度待核实（服务端未返回该窗口数据）")
                    .font(Typo.small).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(old ? Palette.readonlyField : Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)额度" + (old ? "，\(oldValueNote)" : ""))
    }

    /// amount/limit 行文案: USD → "$x / $y", 其他 → "x / y <unit>"
    static func unitLabel(_ amount: Double, _ limit: Double, unit: String?) -> String {
        func f(_ v: Double) -> String {
            String(format: v.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", v)
        }
        if unit?.uppercased() == "USD" { return "$\(f(amount)) / $\(f(limit))" }
        let suffix = unit.map { " \($0)" } ?? ""
        return "\(f(amount)) / \(f(limit))\(suffix)"
    }

    private func resetLine(_ resetsAt: Int?, period: String?) -> String {
        var parts: [String] = []
        if let p = period { parts.append(p) }
        if let r = formatResetAt(resetsAt) { parts.append(r) }
        if parts.isEmpty { return "重置时间未知" }
        return parts.joined(separator: " · ")
    }

    /// 停用与查询失败分别说明；缓存时间可跨 App 重启保留。
    private var oldValueNote: String {
        let capturedAt = row.state?.cache?.generatedAt
            ?? model.lastSuccess[row.id].map { $0.timeIntervalSince1970 * 1000 }
        let time = capturedAt.map { "（\(formatCacheTime($0))）" } ?? ""
        if !row.enabled { return "账号已停用，显示上次查询数据\(time)" }
        if row.state?.cache?.error != nil { return "本次查询未成功，显示上次成功数据\(time)" }
        return "数据已过期，显示上次查询数据\(time)"
    }

    private func resetLine(_ bucket: Bucket?) -> String {
        if let r = formatResetAt(bucket?.resetsAt) { return r }
        return "重置时间未知"
    }
}

// MARK: - 结果条

struct ResultBox: View {
    enum Kind { case ok, error, info, neutral }
    let kind: Kind
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(dotColor).frame(width: 6, height: 6).padding(.top, 5)
            (Text(title).font(Typo.small).bold() + Text(detail.isEmpty ? "" : " · " + detail).font(Typo.small))
                .foregroundStyle(textColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(bgColor))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(borderColor, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var dotColor: Color {
        switch kind {
        case .ok: return Palette.ok
        case .error: return Palette.danger
        case .info: return Palette.accent
        case .neutral: return Palette.muted
        }
    }

    private var textColor: Color {
        switch kind {
        case .error: return Palette.danger
        default: return Palette.muted
        }
    }

    private var bgColor: Color {
        switch kind {
        case .ok: return Palette.surface
        case .error: return Palette.dangerSoft
        default: return Palette.badgeBg
        }
    }

    private var borderColor: Color {
        switch kind {
        case .error: return Palette.danger.opacity(0.35)
        default: return Palette.border
        }
    }
}

/// 进度条 (6pt 圆角, accent 填充)
struct ProgressLine: View {
    let pct: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.barTrack)
                if let p = pct {
                    Capsule().fill(Palette.accent)
                        .frame(width: geo.size.width * CGFloat(min(max(p, 0), 100) / 100))
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("已用 \(pct.map { "\(Int($0.rounded()))%" } ?? "未知")")
    }
}


enum QuotaErrorPresentation {
    static func message(for code: String) -> String {
        switch code {
        case "network": return "无法连接服务，请检查网络后重试"
        case "parse": return "服务返回的数据暂时无法识别，请稍后重试"
        case "no-auth", "auth": return "缺少有效凭证，请检查账号配置或重新登录"
        case "ratelimit": return "查询过于频繁，请稍后再试"
        case "fetch": return "额度查询未完成，请重试"
        case "timeout": return "查询超时，请稍后重试"
        default: return "暂时无法取得额度，请检查配置后重试"
        }
    }
}
