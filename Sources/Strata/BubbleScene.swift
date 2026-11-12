import MapLayout
import SwiftUI

/// One bubble of the bubble view.
struct BubbleCell: Sendable {
    var item: MapItem
    /// Stays the same for the same item in another picture; see `MapCatalog.key(of:in:)`.
    var key: String
    /// 1 for the bubbles of the folder being viewed, 2 and 3 for what is inside them.
    var level: Int
    var parent: Int?
    var children: [Int] = []
    /// The exact cell, used to tell what is under the pointer.
    var raw: MapLayout.Polygon
    /// The pebble that is drawn: the cell pulled in from its neighbours, corners rounded.
    var outline: Path
    /// A sparse field of dots inside the shape, for free space.
    var dots: Path?
    var center: CGPoint
    var tone: Tone
    var label: MarkLabel?
}

/// Everything the bubble view draws for one folder at one size. Colours are left to the
/// theme, so switching themes needs no new layout.
struct BubbleScene: Sendable {
    var cells: [BubbleCell] = []
    var top: [Int] = []
    var size: CGSize

    /// The bubbles under a point, outermost first.
    func hit(_ point: CGPoint) -> [Int] {
        guard let first = top.first(where: { Geometry.contains(cells[$0].raw, point) }) else { return [] }
        var chain = [first]
        while let next = cells[chain[chain.count - 1]].children.first(where: { Geometry.contains(cells[$0].raw, point) }) {
            chain.append(next)
        }
        return chain
    }

    /// How each level is drawn. Deeper levels sit closer together and round less, so the
    /// eye reads the outer bubbles first.
    private struct Style {
        var gap: Double
        /// Width of the parent's body left visible around its children.
        var wall: Double
        var corner: Double
    }
    private static let styles = [
        Style(gap: 11, wall: 4.5, corner: 30),
        Style(gap: 4.6, wall: 2.2, corner: 13),
        Style(gap: 1.8, wall: 0, corner: 5),
    ]
    private static let innerShifts: [[Double]] = [
        [0.0, -0.045, 0.040, -0.022, 0.060, -0.062, 0.024, -0.036],
        [0.0, -0.016, 0.016, -0.008, 0.024, -0.024],
    ]

    static func build(catalog: MapCatalog, focus: Int, size: CGSize) -> BubbleScene {
        var scene = BubbleScene(size: size)
        guard size.width > 80, size.height > 80 else { return scene }
        var standIn = -100

        func add(_ item: MapItem, key: String, level: Int, parent: Int?, raw: MapLayout.Polygon, tone: Tone) -> Int? {
            let style = styles[level - 1]
            let shape = Geometry.soften(Geometry.inset(raw, by: style.gap / 2), cap: style.corner)
            guard shape.count >= 3, Geometry.area(shape) > 6 else { return nil }
            let center = Geometry.centroid(shape)
            var cell = BubbleCell(item: item, key: key, level: level, parent: parent, raw: raw, outline: path(shape),
                                  center: center, tone: tone)
            cell.label = label(for: item, shape: shape, center: center, level: level)
            if item.kind == .free { cell.dots = dotField(in: Geometry.inset(shape, by: 9)) }
            scene.cells.append(cell)
            let index = scene.cells.count - 1
            if let parent { scene.cells[parent].children.append(index) }
            return index
        }

        func subdivide(_ parentIndex: Int, level: Int) {
            let parent = scene.cells[parentIndex]
            let style = styles[level - 2]
            let room = Geometry.soften(Geometry.inset(parent.raw, by: style.gap / 2 + style.wall), cap: style.corner * 0.8)
            guard room.count >= 3, Geometry.area(room) > (level == 2 ? 7_000 : 4_200) else { return }
            let kids = condensed(catalog.children(of: parent.item), minimumShare: level == 2 ? 0.02 : 0.045,
                                 limit: level == 2 ? 16 : 9, standIn: &standIn)
            guard kids.count > 1 else { return }

            let shifts = innerShifts[level - 2]
            let polygons = BubbleLayout.ordered(sizes: kids.map { Double($0.size) }, in: room)
            for (index, (kid, raw)) in zip(kids, polygons).enumerated() where raw.count >= 3 {
                let tone = kid.kind == .small
                    ? parent.tone.shifted(lightness: -0.05, chroma: 0.8)
                    : parent.tone.shifted(lightness: shifts[index % shifts.count], hue: level == 2 ? Double(index % 3 - 1) * 4 : 0)
                if let cell = add(kid, key: catalog.key(of: kid, in: parent.key), level: level, parent: parentIndex, raw: raw, tone: tone),
                   level == 2, kid.kind == .folder {
                    subdivide(cell, level: 3)
                }
            }
        }

        let focusKey = catalog.key(ofFolder: focus)
        let region = Geometry.roundedRect(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), radius: 30)
        let top = condensed(catalog.items(in: focus), minimumShare: 0.004, limit: 22, standIn: &standIn)
        let polygons = BubbleLayout.ordered(sizes: top.map { Double($0.size) }, in: region)
        var family = 0
        for (item, raw) in zip(top, polygons) where raw.count >= 3 {
            let tone: Tone
            switch item.kind {
            case .free: tone = Tone(role: .free)
            case .hidden, .unscanned: tone = Tone(role: .hidden)
            case .small: tone = Tone(role: .neutral)
            case .folder, .file:
                tone = Tone(role: .family(family))
                family += 1
            }
            guard let cell = add(item, key: catalog.key(of: item, in: focusKey), level: 1, parent: nil, raw: raw, tone: tone) else { continue }
            scene.top.append(cell)
            if item.kind == .folder { subdivide(cell, level: 2) }
        }
        return scene
    }

    /// The deepest bubble standing for one of `ids`, for zooming into or out of it.
    func deepestCell(of ids: Set<Int>) -> Int? {
        cells.indices.filter { ids.contains(cells[$0].item.id) }.max { cells[$0].level < cells[$1].level }
    }

    private static func path(_ polygon: MapLayout.Polygon) -> Path {
        var path = Path()
        path.addLines(polygon)
        path.closeSubpath()
        return path
    }

    /// The name, and the size under it when there is room, fitted to the widest clear line
    /// through the middle of the shape.
    private static func label(for item: MapItem, shape: MapLayout.Polygon, center: CGPoint, level: Int) -> MarkLabel? {
        guard let across = Geometry.horizontalSpan(shape, y: center.y),
              let down = Geometry.verticalSpan(shape, x: center.x) else { return nil }
        let width = min(center.x - across.lowerBound, across.upperBound - center.x) * 2 - (level == 1 ? 24 : 12)
        let height = min(center.y - down.lowerBound, down.upperBound - center.y) * 2
        let large = level == 1 && Geometry.area(shape) > 46_000
        // A name that does not fit is first tried smaller, and only then cut short.
        let sizes: [CGFloat] = level == 1 ? (large ? [15] : [13, 11.5, 10.5]) : level == 2 ? [11.5, 10.5] : [10]
        let nameSize = sizes.first { TextMeasure.width(item.title, size: $0, bold: true) <= width } ?? sizes[sizes.count - 1]
        guard width >= 26, height >= nameSize + 8,
              let name = TextMeasure.fitted(item.title, width: width, size: nameSize, bold: true) else { return nil }
        let size = Format.size(item.size)
        let showSize = level < 3 && height >= nameSize * 2 + 14
            && TextMeasure.width(size, size: nameSize - 1, bold: false) <= width
        return MarkLabel(name: name, size: showSize ? size : nil, fontSize: nameSize)
    }
}

/// A sparse field of dots filling a shape: how free space is marked as empty.
func dotField(in shape: MapLayout.Polygon) -> Path {
    var dots = Path()
    guard shape.count >= 3 else { return dots }
    let box = Geometry.bounds(shape)
    var row = 0
    for y in stride(from: box.minY, through: box.maxY, by: 11) {
        // Every other row is shifted half a step, which reads as a field, not a grid.
        for x in stride(from: box.minX + (row % 2 == 0 ? 0 : 6.5), through: box.maxX, by: 13)
        where Geometry.contains(shape, CGPoint(x: x, y: y)) {
            dots.addEllipse(in: CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2))
        }
        row += 1
    }
    return dots
}
