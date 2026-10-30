import SwiftUI

struct FloatingView: View {
    @ObservedObject var engine: DataEngine
    @ObservedObject var controller: PanelController
    let expanded: Bool
    let onToggle: () -> Void
    var onQuit: () -> Void = {}
    var onRefreshAll: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var style: PanelStyle { controller.style }
    private var bgOpacity: Double { controller.bgOpacity }
    private var textOpacity: Double { controller.textOpacity }

    var body: some View {
        VStack(spacing: 6) {
            if expanded {
                VStack(alignment: .leading, spacing: style == .compact ? 2 : 6) {
                    ForEach(engine.states) { st in
                        providerCard(st)
                    }
                    HStack {
                        Text("刷新 \(engine.lastRefresh.map { Self.time($0) } ?? "—")")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("收起", action: onToggle).buttonStyle(.plain)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onToggle() } // 展开态双击收起
            } else {
                HStack(spacing: 10) {
                    ForEach(engine.states) { st in
                        HStack(spacing: 4) {
                            ProviderBadge(icon: st.manifest.icon, label: st.manifest.label,
                                          accent: brandColor(st.manifest.accent), size: 16)
                            PctText(pct: st.worstPct, size: 13, weight: .bold)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .onTapGesture(count: 2) { onToggle() }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onToggle() }
                .help("双击展开明细, 右键菜单")
            }
        }
        .opacity(textOpacity)
        .background(panelBackground)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: style)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: bgOpacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: textOpacity)
        // 右键菜单: 关闭悬浮窗 / 刷新余额 / 供应商管理 / 退出
        .contextMenu {
            Button("关闭悬浮窗") { controller.toggle() }
            Button("刷新余额") { onRefreshAll() }
            Button("设置中心…") { onOpenSettings() }
            Divider()
            Button("退出") { onQuit() }
        }
    }

    /// 按风格渲染背景; 边框用 primary 自适应明暗 (HIG 9.4)
    /// reduceTransparency 时弃 material 用实底 (HIG 9.5)
    @ViewBuilder
    private var panelBackground: some View {
        switch style {
        case .card:
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1.0 : bgOpacity))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        case .glass:
            RoundedRectangle(cornerRadius: 18)
                .fill(reduceTransparency
                      ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                      : AnyShapeStyle(.ultraThinMaterial.opacity(bgOpacity)))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.2)))
                .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        case .compact:
            RoundedRectangle(cornerRadius: 8)
                .fill(reduceTransparency
                      ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                      : AnyShapeStyle(.thinMaterial.opacity(bgOpacity)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        case .list:
            RoundedRectangle(cornerRadius: 12)
                .fill(reduceTransparency
                      ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                      : AnyShapeStyle(.thinMaterial.opacity(bgOpacity)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        }
    }

    /// 单家区块: 按风格渲染布局结构 (共用 ProviderBadge/PctText/CountdownChip 设计零件)
    @ViewBuilder
    private func providerCard(_ st: ProviderState) -> some View {
        switch style {
        case .card: cardCard(st)
        case .glass: glassRow(st)
        case .compact: compactRow(st)
        case .list: listBlock(st)
        }
    }

    /// 头行: 徽标 + 名称 + 收藏 (四风格通用)
    private func headerRow(_ st: ProviderState, badgeSize: CGFloat) -> some View {
        HStack(spacing: 7) {
            ProviderBadge(icon: st.manifest.icon, label: st.manifest.label,
                          accent: brandColor(st.manifest.accent), size: badgeSize)
            Text(st.manifest.fullName)
                .font(.system(.caption, design: .rounded).weight(.semibold))
            Spacer()
            starButton(st)
        }
    }

    /// 桶行: 标签 + 进度 + 数字 + 倒计时 chip (四风格通用)
    private func bucketRow(_ r: MiniRow, barWidth: CGFloat, barHeight: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(r.label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            UsageBar(pct: r.bucket.usedPercentage)
                .frame(width: barWidth, height: barHeight)
            PctText(pct: r.bucket.usedPercentage, size: 12, weight: .semibold)
                .frame(width: 38, alignment: .trailing)
            if let rt = resetText(r.bucket) {
                CountdownChip(text: rt)
            }
        }
    }

    /// 卡片风格: 每供应商一张圆角卡片
    private func cardCard(_ st: ProviderState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow(st, badgeSize: 24)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(zipBucketRows(st), id: \.label) { r in
                    bucketRow(r, barWidth: 96, barHeight: 6)
                }
            }
            .padding(.leading, 31) // 与徽标右侧文字对齐
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    /// 玻璃风格: 无卡底, hairline 分隔
    private func glassRow(_ st: ProviderState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow(st, badgeSize: 24)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(zipBucketRows(st), id: \.label) { r in
                    bucketRow(r, barWidth: 96, barHeight: 5)
                }
            }
            .padding(.leading, 31)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    /// 紧凑风格: 单行 (徽标 + 每桶 点条+数字+chip 横排), 数据密度最高
    private func compactRow(_ st: ProviderState) -> some View {
        HStack(spacing: 6) {
            ProviderBadge(icon: st.manifest.icon, label: st.manifest.label,
                          accent: brandColor(st.manifest.accent), size: 18)
            ForEach(zipBucketRows(st), id: \.label) { r in
                HStack(spacing: 3) {
                    Text(r.label).font(.system(size: 9, design: .rounded)).foregroundStyle(.tertiary)
                    DotBar(pct: r.bucket.usedPercentage)
                    PctText(pct: r.bucket.usedPercentage, size: 12, weight: .semibold)
                    if let rt = resetText(r.bucket) {
                        CountdownChip(text: rt)
                    }
                }
            }
            Spacer()
            starButton(st)
        }
        .padding(.vertical, 2)
    }

    /// 列表风格: 纵列无底, 最省空间
    private func listBlock(_ st: ProviderState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ProviderBadge(icon: st.manifest.icon, label: st.manifest.label,
                              accent: brandColor(st.manifest.accent), size: 20)
                Text(st.manifest.fullName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                starButton(st)
            }
            ForEach(zipBucketRows(st), id: \.label) { r in
                bucketRow(r, barWidth: 84, barHeight: 5)
                    .padding(.leading, 2)
            }
        }
    }

    private func starButton(_ st: ProviderState) -> some View {
        Button {
            engine.setIconProvider(engine.iconProviderSlug == st.slug ? nil : st.slug)
        } label: {
            Image(systemName: engine.iconProviderSlug == st.slug ? "star.fill" : "star")
                .font(.caption2)
                .foregroundStyle(engine.iconProviderSlug == st.slug ? .yellow : .secondary)
        }
        .buttonStyle(.plain)
        .help("设为图标默认显示")
        .accessibilityLabel(engine.iconProviderSlug == st.slug ? "取消图标默认显示" : "设为图标默认显示")
    }

    /// 重置倒计时文本 (如 "3h15m"); 无值则 nil
    private func resetText(_ bucket: Bucket) -> String? {
        HUDFmt.resetCountdown(bucket.resetsAt, now: Date())
    }

    /// 最后刷新时间 HH:mm:ss (不随秒数重渲染, 避免"0s前"卡住)
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
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
