import SwiftUI

struct RecommendedScheduleTimes: View {
    static let times = ["06:00", "11:01", "16:02"]
    var onApply: ([String]) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("推荐时间")).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text(Self.times.joined(separator: " · "))
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            Button(L10n.tr("一键设置")) { onApply(Self.times) }
                .barButton().fixedSize()
                .help(L10n.tr("替换为推荐时间，保存计划后生效；不自动开启调度。"))
                .accessibilityIdentifier("schedule.apply-recommended-times")
        }
    }
}
