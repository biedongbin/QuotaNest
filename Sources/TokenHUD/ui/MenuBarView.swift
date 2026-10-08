import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: DataEngine
    @ObservedObject var panelCtrl: PanelController
    var onOpenSettings: () -> Void
    var onTogglePanel: () -> Void
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            panelControls
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    onTogglePanel()
                } label: {
                    Label("切换悬浮窗", systemImage: panelCtrl.isVisible ? "rectangle.on.rectangle" : "rectangle")
                }
                HStack {
                    Button { onRefresh() } label: {
                        Label("立即刷新", systemImage: "arrow.clockwise")
                    }
                    if engine.isRefreshingAll {
                        ProgressView().controlSize(.small)
                    }
                }
                Button { onOpenSettings() } label: {
                    Label("供应商管理…", systemImage: "slider.horizontal.3")
                }
                Divider()
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("退出", systemImage: "power")
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .frame(width: 290)
    }

    /// 悬浮窗外观控制: 风格切换 + 背景/文字透明度
    private var panelControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("悬浮窗").font(.caption).foregroundStyle(.secondary)
                ForEach(PanelStyle.allCases) { s in
                    Button(s.label) { panelCtrl.setStyle(s) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(panelCtrl.style == s ? .accentColor : .secondary)
                }
            }
            HStack(spacing: 6) {
                Text("背景").font(.caption2).foregroundStyle(.secondary)
                Slider(value: bgBinding, in: 0.1...1.0).controlSize(.mini)
                Text("文字").font(.caption2).foregroundStyle(.secondary)
                Slider(value: textBinding, in: 0.1...1.0).controlSize(.mini)
            }
        }
    }

    private var bgBinding: Binding<Double> {
        Binding(get: { panelCtrl.bgOpacity }, set: { panelCtrl.setBgOpacity($0) })
    }
    private var textBinding: Binding<Double> {
        Binding(get: { panelCtrl.textOpacity }, set: { panelCtrl.setTextOpacity($0) })
    }

    /// 单供应商块: 徽标 + 名称 + 右侧大数字; 下方桶行
    @ViewBuilder
    private func providerSection(_ st: ProviderState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                ProviderBadge(icon: st.manifest.icon, label: st.manifest.label,
                              accent: brandColor(st.manifest.accent), size: 26)
                Text(st.manifest.fullName)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                Spacer()
                if st.cache?.error == "auth" {
                    Text("需登录").foregroundStyle(.yellow).font(.caption)
                } else {
                    PctText(pct: st.worstPct, size: 20, weight: .bold)
                }
            }
            ForEach(bucketPairs(st), id: \.0) { label, bucket in
                BucketRow(label: label, bucket: bucket, stale: st.isStale, now: Date())
                    .padding(.leading, 34)
            }
        }
        .padding(.vertical, 1)
    }

    private func bucketPairs(_ st: ProviderState) -> [(String, Bucket)] {
        var out: [(String, Bucket)] = []
        if let b = st.cache?.fiveHour, let l = st.manifest.buckets["five_hour"] { out.append((l, b)) }
        if let b = st.cache?.sevenDay, let l = st.manifest.buckets["seven_day"] { out.append((l, b)) }
        if let b = st.cache?.monthly, let l = st.manifest.buckets["monthly"] { out.append((l, b)) }
        return out
    }
}
