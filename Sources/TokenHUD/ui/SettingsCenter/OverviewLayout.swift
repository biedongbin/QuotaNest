import SwiftUI

/// 窗口数据放得下时等宽并排，否则整组纵向排布。
struct EqualWidthWindowLayout: Layout {
    var minimumWidth: CGFloat = 170
    var spacing: CGFloat = 12

    private func columns(width: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 1 }
        return width >= CGFloat(count) * minimumWidth + CGFloat(count - 1) * spacing ? count : 1
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = max(0, proposal.width ?? minimumWidth)
        let count = columns(width: width, count: subviews.count)
        let columnWidth = max(0, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
        let heights = subviews.map { $0.sizeThatFits(.init(width: columnWidth, height: nil)).height }
        let height = count == 1 ? heights.reduce(0, +) + CGFloat(heights.count - 1) * spacing : (heights.max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = columns(width: bounds.width, count: subviews.count)
        let width = max(0, (bounds.width - CGFloat(count - 1) * spacing) / CGFloat(count))
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.init(width: width, height: nil))
            let x = count == 1 ? bounds.minX : bounds.minX + CGFloat(index) * (width + spacing)
            subview.place(at: CGPoint(x: x, y: y), proposal: .init(width: width, height: size.height))
            if count == 1 { y += size.height + spacing }
        }
    }
}
