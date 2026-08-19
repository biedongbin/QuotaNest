import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: DataEngine
    var onOpenSettings: () -> Void
    var onTogglePanel: () -> Void
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(engine.states) { st in
                providerSection(st)
            }
            if !engine.registryErrors.isEmpty {
                Divider()
                ForEach(engine.registryErrors.sorted(by: { $0.key < $1.key }), id: \.key) { slug, msg in
                    Text("\(slug): \(msg)").font(.caption).foregroundStyle(.orange)
                }
            }
            if engine.nodeMissing {
                Text("node 未找到 — 供应商管理中手动指定").font(.caption).foregroundStyle(.orange)
            }
            Divider()
            Button("切换悬浮窗") { onTogglePanel() }
            Button("立即刷新") { onRefresh() }
            Button("供应商管理…") { onOpenSettings() }
            Divider()
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
        .padding(4)
    }

    @ViewBuilder
    private func providerSection(_ st: ProviderState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(st.manifest.label).bold()
                Spacer()
                if st.cache?.error == "auth" {
                    Text("需登录").foregroundStyle(.yellow).font(.caption)
                } else if let p = st.worstPct {
                    Text(formatPct(p)).foregroundStyle(hudColor(HUDFmt.pctColor(p))).monospacedDigit()
                } else {
                    Text("加载中").foregroundStyle(.secondary).font(.caption)
                }
            }
            ForEach(bucketPairs(st), id: \.0) { label, bucket in
                BucketRow(label: label, bucket: bucket, stale: st.isStale, now: Date())
            }
        }
    }

    private func bucketPairs(_ st: ProviderState) -> [(String, Bucket)] {
        var out: [(String, Bucket)] = []
        if let b = st.cache?.fiveHour, let l = st.manifest.buckets["five_hour"] { out.append((l, b)) }
        if let b = st.cache?.sevenDay, let l = st.manifest.buckets["seven_day"] { out.append((l, b)) }
        if let b = st.cache?.monthly, let l = st.manifest.buckets["monthly"] { out.append((l, b)) }
        return out
    }
}
