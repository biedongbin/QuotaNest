import SwiftUI

func hudColor(_ c: HUDFmt.Color) -> Color {
    switch c {
    case .red: return .red
    case .yellow: return .yellow
    case .green: return .green
    case .dim: return .secondary.opacity(0.6)
    }
}

func formatPct(_ p: Double?) -> String {
    guard let p else { return "--%" }
    return "\(Int(p.rounded()))%"
}

/// 一行桶状态: "5h: [====  ] 47% (2h13m)*"
struct BucketRow: View {
    let label: String
    let bucket: Bucket
    let stale: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text("\(label):").foregroundStyle(.secondary)
            ProgressView(value: min(max(bucket.usedPercentage ?? 0, 0), 100))
                .progressViewStyle(.linear)
                .frame(width: 110)
            Text(formatPct(bucket.usedPercentage))
                .foregroundStyle(hudColor(HUDFmt.pctColor(bucket.usedPercentage)))
                .monospacedDigit().frame(width: 42, alignment: .trailing)
            if let cd = HUDFmt.resetCountdown(bucket.resetsAt, now: now) {
                Text("(\(cd))").foregroundStyle(.secondary).font(.caption)
            }
            if stale { Text("*").foregroundStyle(.secondary) }
        }
    }
}
