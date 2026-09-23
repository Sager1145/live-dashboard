import SwiftUI

/// A simple wrapping horizontal-then-vertical layout, like a wrapping HStack, spacing 6pt
/// between items on both axes. Used for chip rows (e.g. day labels) that would otherwise
/// overflow the card at accessibility text sizes.
public struct FlowLayout: Layout {
    public var horizontalSpacing: CGFloat
    public var verticalSpacing: CGFloat

    public init(horizontalSpacing: CGFloat = 6, verticalSpacing: CGFloat = 6) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(for: subviews, maxWidth: maxWidth)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        return CGSize(width: min(width, maxWidth), height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    public func makeCache(subviews: Subviews) -> () {}

    private struct RowItem { let subview: LayoutSubview; let size: CGSize }
    private struct Row { var items: [RowItem]; var width: CGFloat; var height: CGFloat }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(items: [], width: 0, height: 0)
        for subview in subviews {
            // Proposing the container's width (rather than `.unspecified`) lets a long chip's
            // text wrap or shrink to fit at accessibility text sizes instead of reporting an
            // unbounded ideal width that overflows the card.
            var size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            size.width = min(size.width, maxWidth)
            let projectedWidth = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if projectedWidth > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = Row(items: [], width: 0, height: 0)
            }
            current.width = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
            current.items.append(RowItem(subview: subview, size: size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
