import SwiftUI

// MARK: - 额度 tab

struct QuotaTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow

    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("额度").font(Typo.section).foregroundStyle(Palette.ink)
                        Text("最近查询：\(lastTimeText)").font(Typo.small).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    if row.canQuery {
                        Button(model.running.contains(row.id) ? "查询中…" : "查询额度") { model.query(row.id) }
                            .barButton(.primary)
                            .disabled(model.running.contains(row.id))
                    }
                }
                .padding(.bottom, 12)

                if model.running.contains(row.id) {
                    ResultBox(kind: .info, title: "查询中…",
                              detail: "已向 \(row.plugin.manifest.fullName) 发起额度查询，窗口保持可操作。")
                } else {
                    ResultBox(kind: resultKind, title: resultTitle, detail: resultDetail)
                }

                if !row.canQuery {
                    Text("\(row.plugin.manifest.fullName) 未声明 queryUrl，额度查询尚未适配，因此不显示 5 小时 / 本周 / 本月数值。")
                        .font(Typo.small).foregroundStyle(Palette.muted)
                        .padding(.top, 12)
                } else {
                    quotaGrid.padding(.top, 12)
                }

                techDetails.padding(.top, 12)
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
        guard let c = row.state?.cache else { return .neutral }
        return c.error != nil ? .error : .ok
    }

    private var resultTitle: String {
        guard let c = row.state?.cache else { return "尚未查询" }
        if c.error != nil { return "查询失败" }
        if c.stale == true { return "最近查询（缓存已过期）" }
        return "最近查询成功"
    }

    private var resultDetail: String {
        guard let c = row.state?.cache else {
            return row.canQuery ? "点击「查询额度」后在这里显示该账号的额度与重置时间。"
                                : "该账号没有额度查询能力。"
        }
        var parts: [String] = [formatCacheTime(c.generatedAt)]
        if let run = model.lastRun[row.id] {
            parts.append("耗时 \(run.ms) ms")
        }
        if let e = c.error {
            parts.append(DataEngine.reason(for: e))
        } else if let p = c.fiveHour?.usedPercentage {
            parts.append("5 小时已用 \(Int(p.rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 三卡

    private var quotaGrid: some View {
        HStack(alignment: .top, spacing: 8) {
            quotaCard("5 小时", row.state?.cache?.fiveHour)
            quotaCard("本周", row.state?.cache?.sevenDay)
            quotaCard("本月", row.state?.cache?.monthly)
        }
    }

    private func quotaCard(_ label: String, _ bucket: Bucket?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).font(Typo.small).foregroundStyle(Palette.muted)
                Spacer()
                if let p = bucket?.usedPercentage {
                    Text("\(Int(p.rounded()))%").font(Typo.small).foregroundStyle(Palette.muted)
                }
            }
            if let p = bucket?.usedPercentage {
                Text("\(Int(p.rounded()))%")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .padding(.top, 6)
                ProgressLine(pct: p)
                    .padding(.top, 10)
                Text(resetLine(bucket))
                    .font(Typo.small).foregroundStyle(Palette.muted)
                    .padding(.top, 6)
            } else {
                Text("—")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 6)
                Text("此供应商未提供该窗口额度")
                    .font(Typo.small).foregroundStyle(Palette.muted)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)额度")
    }

    private func resetLine(_ bucket: Bucket?) -> String {
        if let r = formatResetAt(bucket?.resetsAt) { return r }
        return "重置时间未知"
    }

    // MARK: 技术详情

    private var techDetails: some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                KeyValueRow("查询端点", mono: true) {
                    Text(row.plugin.manifest.queryUrl ?? "未适配")
                }
                KeyValueRow("授权方式") { Text(row.authLabel) }
                KeyValueRow("最近错误码") {
                    Text(row.state?.cache?.error ?? "—")
                }
                KeyValueRow("缓存时间") {
                    Text(formatCacheTime(row.state?.cache?.generatedAt))
                }
                KeyValueRow("数据来源") {
                    Text(row.canQuery ? "\(row.plugin.manifest.fullName) 官方额度接口" : "未适配")
                }
            }
            .padding(.top, 4)
        } label: {
            Text("技术详情").font(Typo.small).foregroundStyle(Palette.muted)
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
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
