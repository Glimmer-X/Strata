import AppKit
import MapLayout
import SwiftUI

/// The opening of a film (`Film`): pebbles grow over the whole frame from top to bottom, a
/// question pops up on the largest one, then they fall away from top to bottom and leave the
/// window showing.
struct FilmIntro: Decodable {
    /// The question, one string per line.
    var question: [String]
    /// When the first and the last pebble start to grow.
    var grow: [Double]
    /// When the question pops up.
    var askAt: Double
    /// When the first and the last pebble start to go.
    var vanish: [Double]
    /// When the window's content appears, once the pebbles are gone.
    var reveal: Double
    /// Picks the pebbles' sizes; another number gives another pattern.
    var seed: UInt64

    /// The pebbles laid out over a frame, ready to draw at any moment.
    struct Layout {
        struct Pebble {
            var outline: Path
            var center: CGPoint
            var tone: Tone
            /// Where it stands from top (0) to bottom (1), which sets when it moves.
            var depth: Double
            /// The wall colour shows when the pebble has pebbles inside it.
            var hasInside: Bool
        }

        var pebbles: [Pebble] = []
        /// The pebble carrying the question.
        var host = 0
        var fontSize: CGFloat = 50
    }

    /// Of a few patterns from the seed, the one whose question pebble sits nearest the middle.
    func layout(in size: CGSize) -> Layout {
        let middle = CGPoint(x: size.width / 2, y: size.height * 0.45)
        return (0..<24).map { layout(in: size, seed: seed &+ UInt64($0)) }.min { a, b in
            let pa = a.pebbles[a.host].center, pb = b.pebbles[b.host].center
            return hypot(pa.x - middle.x, pa.y - middle.y) < hypot(pb.x - middle.x, pb.y - middle.y)
        }!
    }

    private func layout(in size: CGSize, seed: UInt64) -> Layout {
        var random = SeededRandom(seed: seed)
        var result = Layout()
        // Pebbles of varied sizes, a few of them large. The layout fills the frame in the
        // order of the sizes, so the question's pebble goes where the running total reaches
        // the middle of the frame.
        var sizes: [Double] = []
        while sizes.reduce(0, +) < 0.86 {
            sizes.append(random.next() < 0.1 ? 0.05 + random.next() * 0.02 : 0.008 + pow(random.next(), 2.2) * 0.045)
        }
        var total = 0.0
        let hostCell = sizes.firstIndex { total += $0; return total > 0.36 } ?? 0
        sizes.insert(0.15, at: hostCell)
        let frame = Geometry.roundedRect(CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40), radius: 0)
        let cells = BubbleLayout.ordered(sizes: sizes, in: frame)

        func add(_ raw: MapLayout.Polygon, gap: Double, corner: Double, tone: Tone, inside: Bool) -> Int? {
            let shape = Geometry.soften(Geometry.inset(raw, by: gap / 2), cap: corner)
            guard shape.count >= 3, Geometry.area(shape) > 40 else { return nil }
            var path = Path()
            path.addLines(shape)
            path.closeSubpath()
            let center = Geometry.centroid(shape)
            result.pebbles.append(Layout.Pebble(outline: path, center: center, tone: tone,
                                                depth: min(max(center.y / size.height, 0), 1), hasInside: inside))
            return result.pebbles.count - 1
        }

        for (index, raw) in cells.enumerated() where raw.count >= 3 {
            let tone = Tone(role: .family(index))
            let big = Geometry.area(raw) > size.width * size.height * 0.03
            guard let pebble = add(raw, gap: 14, corner: 40, tone: tone, inside: big && index != hostCell) else { continue }
            if index == hostCell { result.host = pebble }
            // Larger pebbles hold a few smaller ones, as folders do on the map.
            if big, index != hostCell {
                let room = Geometry.soften(Geometry.inset(raw, by: 7 + 3), cap: 30)
                let count = 3 + Int(random.next() * 4)
                let inner = (0..<count).map { _ in 0.4 + random.next() }
                for (k, kid) in BubbleLayout.ordered(sizes: inner, in: room).enumerated() where kid.count >= 3 {
                    _ = add(kid, gap: 6, corner: 16, tone: tone.shifted(lightness: [0.0, -0.045, 0.04, -0.022, 0.06, -0.062][k % 6]),
                            inside: false)
                }
            }
        }

        // The largest size that fits the widest line across the host pebble.
        let host = cells[hostCell]
        let center = Geometry.centroid(host)
        if let across = Geometry.horizontalSpan(Geometry.inset(host, by: 40), y: center.y) {
            let room = (across.upperBound - across.lowerBound) * 0.82
            let widest = question.map { TextMeasure.width($0, size: 100, bold: true) }.max() ?? 1
            result.fontSize = min(64, 100 * room / widest)
        }
        return result
    }

    /// How large a pebble is drawn at time `t`: grows with a little overshoot, then shrinks away.
    func scale(of pebble: Layout.Pebble, at t: Double) -> Double {
        let born = grow[0] + (grow[1] - grow[0]) * pebble.depth
        let gone = vanish[0] + (vanish[1] - vanish[0]) * pebble.depth
        let up = Spring.response(t - born)
        let x = min(max((t - gone) / 0.42, 0), 1)
        return up * (1 - x * x * (3 - 2 * x))
    }
}

/// The intro drawn over the frame.
struct FilmIntroView: View {
    let intro: FilmIntro
    let layout: FilmIntro.Layout
    let theme: Theme
    let time: Double

    var body: some View {
        Canvas { context, _ in
            for (index, pebble) in layout.pebbles.enumerated() {
                let s = intro.scale(of: pebble, at: time)
                guard s > 0.001 else { continue }
                var local = context
                local.translateBy(x: pebble.center.x, y: pebble.center.y)
                local.scaleBy(x: s, y: s)
                local.translateBy(x: -pebble.center.x, y: -pebble.center.y)
                let fill = pebble.hasInside ? theme.wall(pebble.tone) : theme.fill(pebble.tone)
                local.fill(pebble.outline, with: .color(fill.color))
                if index == layout.host { drawQuestion(in: &local, on: theme.fill(pebble.tone), center: pebble.center, scale: s) }
            }
        }
    }

    private func drawQuestion(in context: inout GraphicsContext, on fill: OKColor, center: CGPoint, scale: Double) {
        let pop = Spring.response(time - intro.askAt)
        guard pop > 0.001 else { return }
        var text = context
        text.translateBy(x: center.x, y: center.y)
        text.scaleBy(x: pop, y: pop)
        text.opacity = min(pop, 1)
        let lineHeight = layout.fontSize * 1.28
        let top = -lineHeight * Double(intro.question.count - 1) / 2
        for (index, line) in intro.question.enumerated() {
            text.draw(Text(line).font(.system(size: layout.fontSize, weight: .semibold))
                .foregroundStyle(theme.ink(on: fill).color),
                      at: CGPoint(x: 0, y: top + lineHeight * Double(index)))
        }
    }
}

/// A small repeatable random source, so the same seed always gives the same pebbles.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    /// 0..<1
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}
