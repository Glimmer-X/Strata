import MapLayout
import SwiftUI

/// One bar of the flow view.
struct FlowBar: Sendable {
    var item: MapItem
    /// Stays the same for the same item in another picture; see `MapCatalog.key(of:in:)`.
    var key: String
    var level: Int
    var parent: Int?
    var children: [Int] = []
    var rect: CGRect
    var tone: Tone
    var label: MarkLabel?
    /// The dot field of free space.
    var dots: Path?
}

/// The band joining a bar to one of the bars it contains: from a stretch of the parent's
/// bottom edge to the child's top edge.
struct FlowRibbon: Sendable {
    var parent: Int
    var child: Int
    var top: ClosedRange<CGFloat>
    var topY: CGFloat
    var bottom: ClosedRange<CGFloat>
    var bottomY: CGFloat
    var path: Path

    init(parent: Int, child: Int, top: ClosedRange<CGFloat>, topY: CGFloat, bottom: ClosedRange<CGFloat>, bottomY: CGFloat) {
        self.parent = parent
        self.child = child
        self.top = top
        self.topY = topY
        self.bottom = bottom
        self.bottomY = bottomY
        path = Self.path(top: top, topY: topY, bottom: bottom, bottomY: bottomY)
    }

    /// The band between two stretches, with an S-curve on each side.
    static func path(top: ClosedRange<CGFloat>, topY: CGFloat, bottom: ClosedRange<CGFloat>, bottomY: CGFloat) -> Path {
        let middle = (topY + bottomY) / 2
        var path = Path()
        path.move(to: CGPoint(x: top.lowerBound, y: topY))
        path.addCurve(to: CGPoint(x: bottom.lowerBound, y: bottomY),
                      control1: CGPoint(x: top.lowerBound, y: middle),
                      control2: CGPoint(x: bottom.lowerBound, y: middle))
        path.addLine(to: CGPoint(x: bottom.upperBound, y: bottomY))
        path.addCurve(to: CGPoint(x: top.upperBound, y: topY),
                      control1: CGPoint(x: bottom.upperBound, y: middle),
                      control2: CGPoint(x: top.upperBound, y: middle))
        path.closeSubpath()
        return path
    }
}

/// Everything the flow view draws for one folder at one size.
struct FlowScene: Sendable {
    var bars: [FlowBar] = []
    var ribbons: [FlowRibbon] = []
    var size: CGSize

    /// The deepest bar standing for one of `ids`, for zooming into or out of it.
    func deepestBar(of ids: Set<Int>) -> Int? {
        bars.indices.filter { ids.contains(bars[$0].item.id) }.max { bars[$0].level < bars[$1].level }
    }

    func hit(_ point: CGPoint) -> Int? {
        bars.firstIndex { $0.rect.insetBy(dx: -1.5, dy: 0).contains(point) }
    }

    /// A bar together with everything above and below it.
    func family(of bar: Int) -> Set<Int> {
        var members: Set<Int> = [bar]
        var up = bars[bar].parent
        while let current = up {
            members.insert(current)
            up = bars[current].parent
        }
        var pending = bars[bar].children
        while let current = pending.popLast() {
            members.insert(current)
            pending.append(contentsOf: bars[current].children)
        }
        return members
    }

    private static let levels = 4
    /// Room between two rows, where the ribbons run.
    static let between = 54.0
    private static let shifts: [Double] = [0.0, -0.045, 0.040, -0.022, 0.060, -0.062, 0.024, -0.036]

    static func build(catalog: MapCatalog, focus: Int, size: CGSize) -> FlowScene {
        var scene = FlowScene(size: size)
        guard size.width > 120, size.height > 120 else { return scene }
        var standIn = -100
        let spacing = 4.0
        let rowHeight = min(108, max(40, (Double(size.height) - between * Double(levels - 1)) / Double(levels)))

        let top = condensed(catalog.items(in: focus), minimumShare: 10 / Double(size.width), limit: 16, standIn: &standIn)
        let total = max(top.reduce(0.0) { $0 + Double($1.size) }, 1)
        // Rough points per byte, to decide what would be too thin to draw before laying out.
        let roughScale = Double(size.width) * 0.85 / total

        var entries: [(item: MapItem, key: String, tone: Tone)] = []
        func input(_ item: MapItem, key: String, tone: Tone, depth: Int) -> FlowLayout.Input {
            let id = entries.count
            entries.append((item, key, tone))
            var children: [FlowLayout.Input] = []
            let width = Double(item.size) * roughScale
            if depth < levels, item.kind == .folder, width >= 22 {
                let kids = condensed(catalog.children(of: item), minimumShare: min(1, 9 / width), limit: 9, standIn: &standIn)
                if kids.count > 1 {
                    for (index, kid) in kids.enumerated() {
                        let kidTone = kid.kind == .small
                            ? tone.shifted(lightness: -0.05, chroma: 0.8)
                            : tone.shifted(lightness: shifts[index % shifts.count] * (depth == 1 ? 1 : 0.6))
                        children.append(input(kid, key: catalog.key(of: kid, in: key), tone: kidTone, depth: depth + 1))
                    }
                }
            }
            return FlowLayout.Input(id: id, size: Double(item.size), children: children)
        }

        let focusKey = catalog.key(ofFolder: focus)
        var family = 0
        var roots: [FlowLayout.Input] = []
        for item in top {
            let tone: Tone
            switch item.kind {
            case .free: tone = Tone(role: .free)
            case .hidden, .unscanned: tone = Tone(role: .hidden)
            case .small: tone = Tone(role: .neutral)
            case .folder, .file:
                tone = Tone(role: .family(family))
                family += 1
            }
            roots.append(input(item, key: catalog.key(of: item, in: focusKey), tone: tone, depth: 1))
        }

        let layout = FlowLayout.layout(roots: roots, width: Double(size.width), levels: levels,
                                       rowHeight: rowHeight, between: between, spacing: spacing)
        let offset = max(0, (size.height - layout.size.height) / 2)

        scene.bars = [FlowBar](repeating: FlowBar(item: top[0], key: "", level: 0, rect: .zero, tone: Tone(role: .neutral)),
                               count: entries.count)
        for bar in layout.bars {
            let (item, key, tone) = entries[bar.id]
            let rect = bar.rect.offsetBy(dx: 0, dy: offset)
            scene.bars[bar.id] = FlowBar(item: item, key: key, level: bar.level, parent: bar.parent, rect: rect, tone: tone,
                                         label: label(for: item, rect: rect))
            if item.kind == .free {
                scene.bars[bar.id].dots = dotField(in: Geometry.roundedRect(rect.insetBy(dx: 7, dy: 7), radius: 4))
            }
        }
        for bar in layout.bars {
            if let parent = bar.parent { scene.bars[parent].children.append(bar.id) }
        }
        for ribbon in layout.ribbons {
            scene.ribbons.append(FlowRibbon(parent: ribbon.parent, child: ribbon.child,
                                            top: ribbon.top, topY: ribbon.topY + offset + 2,
                                            bottom: ribbon.bottom, bottomY: ribbon.bottomY + offset - 2))
        }
        return scene
    }

    private static func label(for item: MapItem, rect: CGRect) -> MarkLabel? {
        let width = rect.width - 16
        guard width >= 26, let name = TextMeasure.fitted(item.title, width: width, size: 12.5, bold: true) else { return nil }
        let size = Format.size(item.size)
        let showSize = rect.height >= 44 && TextMeasure.width(size, size: 11.5, bold: false) <= width
        return MarkLabel(name: name, size: showSize ? size : nil, fontSize: 12.5)
    }
}
