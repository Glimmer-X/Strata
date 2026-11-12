import CoreGraphics

/// The flow view: rows of bars whose width is size, one row per folder level, each bar
/// joined to the bars of what it contains by ribbons.
public enum FlowLayout {
    public struct Input {
        public var id: Int
        public var size: Double
        public var children: [Input]
        public init(id: Int, size: Double, children: [Input] = []) {
            self.id = id
            self.size = size
            self.children = children
        }
    }

    public struct Bar: Sendable {
        public var id: Int
        public var parent: Int?
        /// 0 for the top row.
        public var level: Int
        public var rect: CGRect
    }

    /// A band from part of a bar's lower edge down to the upper edge of one of its children.
    public struct Ribbon: Sendable {
        public var parent: Int
        public var child: Int
        public var top: ClosedRange<CGFloat>
        public var bottom: ClosedRange<CGFloat>
        public var topY: CGFloat
        public var bottomY: CGFloat
    }

    public struct Result: Sendable {
        public var bars: [Bar] = []
        public var ribbons: [Ribbon] = []
        public var size: CGSize = .zero
        /// Points per unit of size: the same for every bar, so widths can be compared anywhere.
        public var scale: Double = 0
    }

    private final class Node {
        let input: Input
        var children: [Node] = []
        var width = 0.0
        var inner = 0.0
        var span = 0.0
        init(_ input: Input) { self.input = input }
    }

    /// - Parameters:
    ///   - spacing: gap between neighbouring bars of one row.
    ///   - between: vertical room for the ribbons between two rows.
    public static func layout(roots: [Input], width: Double, levels: Int, rowHeight: Double,
                              between: Double, spacing: Double) -> Result {
        guard !roots.isEmpty, width > 0, levels > 0 else { return Result() }

        func build(_ input: Input, depth: Int) -> Node {
            let node = Node(input)
            if depth < levels { node.children = input.children.map { build($0, depth: depth + 1) } }
            return node
        }
        let top = roots.map { build($0, depth: 1) }
        let total = max(roots.reduce(0) { $0 + $1.size }, .leastNonzeroMagnitude)

        @discardableResult func measure(_ node: Node, _ scale: Double) -> Double {
            node.width = node.input.size * scale
            node.inner = 0
            for child in node.children { node.inner += measure(child, scale) }
            node.inner += spacing * Double(max(node.children.count - 1, 0))
            node.span = max(node.width, node.inner)
            return node.span
        }
        func rowSpan(_ scale: Double) -> Double {
            top.reduce(0) { $0 + measure($1, scale) } + spacing * Double(top.count - 1)
        }

        // Widths grow with the scale while the gaps stay fixed: search for the scale that fits.
        var low = 0.0, high = width / total
        for _ in 0..<48 {
            let middle = (low + high) / 2
            if rowSpan(middle) > width { high = middle } else { low = middle }
        }
        let used = rowSpan(low)

        var result = Result()
        result.scale = low
        var deepest = 0
        func place(_ node: Node, left: Double, level: Int, parent: Int?) {
            let x = left + (node.span - node.width) / 2
            let y = Double(level) * (rowHeight + between)
            deepest = max(deepest, level)
            result.bars.append(Bar(id: node.input.id, parent: parent, level: level,
                                   rect: CGRect(x: x, y: y, width: node.width, height: rowHeight)))
            guard !node.children.isEmpty else { return }
            var childLeft = left + (node.span - node.inner) / 2
            var anchor = x
            for child in node.children {
                place(child, left: childLeft, level: level + 1, parent: node.input.id)
                let childX = childLeft + (child.span - child.width) / 2
                result.ribbons.append(Ribbon(
                    parent: node.input.id, child: child.input.id,
                    top: CGFloat(anchor)...CGFloat(anchor + child.width),
                    bottom: CGFloat(childX)...CGFloat(childX + child.width),
                    topY: CGFloat(y + rowHeight), bottomY: CGFloat(y + rowHeight + between)))
                anchor += child.width
                childLeft += child.span + spacing
            }
        }
        var left = (width - used) / 2
        for node in top {
            place(node, left: left, level: 0, parent: nil)
            left += node.span + spacing
        }
        result.size = CGSize(width: width, height: Double(deepest + 1) * rowHeight + Double(deepest) * between)
        return result
    }
}
