import CoreGraphics
import Testing
@testable import MapLayout

private let square: Polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]

@Test func areaAndCentroidOfASquare() {
    #expect(Geometry.area(square) == 10_000)
    #expect(Geometry.centroid(square) == CGPoint(x: 50, y: 50))
    #expect(Geometry.contains(square, CGPoint(x: 10, y: 90)))
    #expect(!Geometry.contains(square, CGPoint(x: 110, y: 50)))
}

@Test func insetShrinksEverySide() {
    let inner = Geometry.inset(square, by: 10)
    #expect(abs(Geometry.area(inner) - 6_400) < 1e-6)
    #expect(Geometry.inset(square, by: 60).isEmpty)
}

@Test func softeningKeepsMostOfTheArea() {
    let soft = Geometry.soften(square, cap: 12)
    #expect(soft.count > square.count)
    #expect(Geometry.area(soft) > 9_300 && Geometry.area(soft) < 10_000)
}

@Test func equalSitesSplitTheRegionInHalf() {
    let cells = BubbleLayout.powerCells(sites: [CGPoint(x: 25, y: 50), CGPoint(x: 75, y: 50)],
                                        weights: [0, 0], in: square)
    #expect(abs(Geometry.area(cells[0]) - 5_000) < 1e-6)
    #expect(abs(Geometry.area(cells[1]) - 5_000) < 1e-6)
}

@Test func squarifyFillsTheRectangleInProportion() {
    let values = [6.0, 6, 4, 3, 2, 2, 1]
    let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
    let rects = Squarify.rects(values: values, in: rect)
    let total = values.reduce(0, +)
    for (value, r) in zip(values, rects) {
        #expect(abs(Double(r.width * r.height) - value / total * 240_000) < 1)
        #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(r))
    }
}

/// A deterministic spread of sizes like a real folder: a few large, many small.
private func skewedSizes(_ count: Int) -> [Double] {
    (0..<count).map { 1000.0 / Double(($0 + 1) * ($0 + 1)) + 3 }
}

@Test(arguments: [2, 5, 12, 26])
func bubbleAreasMatchTheirSizes(count: Int) {
    let region = Geometry.roundedRect(CGRect(x: 0, y: 0, width: 900, height: 600), radius: 40)
    let sizes = skewedSizes(count)
    let cells = BubbleLayout.ordered(sizes: sizes, in: region)
    #expect(cells.count == count)

    let regionArea = Geometry.area(region)
    let total = sizes.reduce(0, +)
    var covered = 0.0
    for (size, cell) in zip(sizes, cells) {
        let area = Geometry.area(cell)
        covered += area
        let share = size / total
        // Cells that are more than a sliver must be within 3 % of their share.
        if share > 0.01 { #expect(abs(area / regionArea - share) / share < 0.03) }
        #expect(area > 0)
    }
    #expect(abs(covered - regionArea) / regionArea < 1e-6)
}

@Test func aLargerSizeNeverGetsASmallerCell() {
    let region = Geometry.roundedRect(CGRect(x: 0, y: 0, width: 900, height: 600), radius: 40)
    let sizes: [Double] = [274, 230, 191, 63.5, 44.8, 17.4, 16.9, 16.6, 16.6, 12.7, 11.6, 10.4, 8.9, 8.3]
    let areas = BubbleLayout.ordered(sizes: sizes, in: region).map(Geometry.area)
    for i in 1..<areas.count where sizes[i - 1] > sizes[i] * 1.05 {
        #expect(areas[i - 1] > areas[i])
    }
}

@Test func bubblesFollowReadingOrder() {
    let region = Geometry.roundedRect(CGRect(x: 0, y: 0, width: 900, height: 600), radius: 40)
    let cells = BubbleLayout.ordered(sizes: skewedSizes(14), in: region)
    let first = Geometry.centroid(cells[0]), last = Geometry.centroid(cells[13])
    #expect(first.x + first.y < last.x + last.y)
}

@Test func flowBarsShareOneScale() {
    let roots = [
        FlowLayout.Input(id: 1, size: 60, children: [
            FlowLayout.Input(id: 11, size: 40, children: [FlowLayout.Input(id: 111, size: 40)]),
            FlowLayout.Input(id: 12, size: 20),
        ]),
        FlowLayout.Input(id: 2, size: 30, children: [FlowLayout.Input(id: 21, size: 30)]),
        FlowLayout.Input(id: 3, size: 10),
    ]
    let result = FlowLayout.layout(roots: roots, width: 800, levels: 3, rowHeight: 50, between: 40, spacing: 6)
    #expect(result.bars.count == 7)
    let sizes: [Int: Double] = [1: 60, 11: 40, 111: 40, 12: 20, 2: 30, 21: 30, 3: 10]
    for bar in result.bars {
        #expect(abs(Double(bar.rect.width) - sizes[bar.id]! * result.scale) < 1e-6)
        #expect(bar.rect.minX >= -1e-6 && bar.rect.maxX <= 800 + 1e-6)
    }
    // Ribbons leave a parent side by side, covering exactly the width of its children.
    let fromFirst = result.ribbons.filter { $0.parent == 1 }
    #expect(fromFirst.count == 2)
    #expect(abs(fromFirst[0].top.upperBound - fromFirst[1].top.lowerBound) < 1e-6)
    #expect(result.size.height == CGFloat(230))
}
