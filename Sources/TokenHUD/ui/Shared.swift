import SwiftUI

func hudColor(_ c: HUDFmt.Color) -> Color {
    switch c {
    case .red: return Palette.danger
    case .yellow: return Palette.warn
    case .green: return Palette.accent
    case .dim: return Palette.muted
    }
}

func formatPct(_ p: Double?) -> String {
    guard let p else { return "--%" }
    return "\(Int(p.rounded()))%"
}

/// manifest.accent 字符串 → Color (缺省系统强调色)
func brandColor(_ name: String?) -> Color {
    switch name {
    case "blue": return .blue
    case "green": return .green
    case "purple": return .purple
    case "orange": return .orange
    case "teal": return .teal
    case "pink": return .pink
    case "indigo": return .indigo
    case "mint": return .mint
    default: return .accentColor
    }
}

// MARK: - 设计系统零件 (悬浮窗/菜单栏/设置窗共用)

/// 品牌图标块: 圆角方形 + 品牌色渐变底 + SF Symbol / 首字母
/// size: 小(16 折叠/紧凑) / 中(24 列表) / 大(28 展开/菜单)
struct ProviderBadge: View {
    let icon: String?
    let label: String
    let accent: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(accent.opacity(0.1))
            .overlay {
                Group {
                    if let icon {
                        Image(systemName: icon).font(.system(size: size * 0.5, weight: .bold))
                    } else {
                        Text(String(label.prefix(1)).uppercased())
                            .font(.system(size: size * 0.45, weight: .bold))
                    }
                }
                .foregroundStyle(accent)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true) // 装饰性, 名称由相邻 Text 提供
    }
}

/// 大百分比数字: rounded 设计字体 (数据感), 按用量着色
struct PctText: View {
    let pct: Double?
    var size: CGFloat = 15
    var weight: Font.Weight = .semibold

    var body: some View {
        Text(formatPct(pct))
            .font(.system(size: size, weight: weight))
            .monospacedDigit()
            .foregroundStyle(hudColor(HUDFmt.pctColor(pct)))
    }
}

/// 重置倒计时 chip: 小胶囊, 视觉弱于数字
struct CountdownChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// 一行桶状态: "[进度] 47% ⟂ 2h13m" — 菜单栏面板用 (旧名保留兼容)
struct BucketRow: View {
    let label: String
    let bucket: Bucket
    let stale: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
            UsageBar(pct: bucket.usedPercentage)
                .frame(width: 90, height: 6)
            PctText(pct: bucket.usedPercentage, size: 12, weight: .semibold)
                .frame(width: 38, alignment: .trailing)
            if let cd = HUDFmt.resetCountdown(bucket.resetsAt, now: now) {
                CountdownChip(text: cd)
            }
            if stale { Text("*").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

/// 自定义进度条: 圆角胶囊, 渐变填充; 高危 (>=90) 加同色辉光
struct UsageBar: View {
    let pct: Double?
    var style: Style = .thin
    enum Style { case thin, thick }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.barTrack)
                if let p = pct, p > 0 {
                    let w = geo.size.width * CGFloat(min(max(p, 0), 100) / 100)
                    Capsule().fill(p >= 90 ? Palette.warn : Palette.accent)
                        .frame(width: max(0, w))
                }
            }
        }
    }

}

/// 点状进度: 5 格, 按用量点亮 (紧凑风格)
struct DotBar: View {
    let pct: Double?
    private let dots = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<dots, id: \.self) { i in
                Circle()
                    .fill(dotColor(i))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private func dotColor(_ i: Int) -> Color {
        guard let p = pct else { return Color.primary.opacity(0.12) }
        let lit = Int((min(max(p, 0), 100) / 100) * Double(dots))
        if i < lit {
            return hudColor(HUDFmt.pctColor(p))
        }
        return Color.primary.opacity(0.12)
    }
}
