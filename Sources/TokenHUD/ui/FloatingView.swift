import SwiftUI

struct FloatingView: View {
    @ObservedObject var engine: DataEngine
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(engine.states) { st in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(st.manifest.label).bold().font(.caption)
                            ForEach(zipBucketRows(st), id: \.label) { r in
                                BucketRow(label: r.label, bucket: r.bucket, stale: st.isStale, now: Date())
                            }
                        }
                    }
                    HStack {
                        Text("刷新 \(engine.lastRefresh.map { Self.ago($0) } ?? "—")")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("收起", action: onToggle).buttonStyle(.plain)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            } else {
                HStack(spacing: 10) {
                    ForEach(engine.states) { st in
                        HStack(spacing: 3) {
                            Text(st.manifest.label).font(.caption).foregroundStyle(.secondary)
                            Text(formatPct(st.worstPct))
                                .font(.callout).monospacedDigit()
                                .foregroundStyle(hudColor(HUDFmt.pctColor(st.worstPct)))
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .onTapGesture { onToggle() }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.15))
        )
    }

    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        return s < 60 ? "\(s)s前" : "\(s / 60)m前"
    }
}

struct MiniRow { let label: String; let bucket: Bucket }

extension FloatingView {
    func zipBucketRows(_ st: ProviderState) -> [MiniRow] {
        var out: [MiniRow] = []
        if let b = st.cache?.fiveHour, let l = st.manifest.buckets["five_hour"] { out.append(.init(label: l, bucket: b)) }
        if let b = st.cache?.sevenDay, let l = st.manifest.buckets["seven_day"] { out.append(.init(label: l, bucket: b)) }
        if let b = st.cache?.monthly, let l = st.manifest.buckets["monthly"] { out.append(.init(label: l, bucket: b)) }
        return out
    }
}
