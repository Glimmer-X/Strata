import SwiftUI

/// The two ways of drawing a folder.
enum MapMode: String, CaseIterable, Sendable {
    case bubbles, flow
}

/// A laid-out picture of one folder in one of the two views.
enum MapScene: Sendable {
    case bubbles(BubbleScene)
    case flow(FlowScene)

    static func build(_ mode: MapMode, catalog: MapCatalog, focus: Int, size: CGSize) -> MapScene {
        switch mode {
        case .bubbles: return .bubbles(BubbleScene.build(catalog: catalog, focus: focus, size: size))
        case .flow: return .flow(FlowScene.build(catalog: catalog, focus: focus, size: size))
        }
    }

    var mode: MapMode {
        switch self {
        case .bubbles: return .bubbles
        case .flow: return .flow
        }
    }

    /// The deepest mark standing for one of `ids`.
    func deepestMark(of ids: Set<Int>) -> Int? {
        switch self {
        case .bubbles(let scene): return scene.deepestCell(of: ids)
        case .flow(let scene): return scene.deepestBar(of: ids)
        }
    }

    /// The colour an item of the outermost level has, so the list can match it.
    func tone(ofTopItem id: Int) -> Tone? {
        switch self {
        case .bubbles(let scene): return scene.top.lazy.map { scene.cells[$0] }.first { $0.item.id == id }?.tone
        case .flow(let scene): return scene.bars.first { $0.level == 0 && $0.item.id == id }?.tone
        }
    }
}

/// How a new picture replaces the one before it.
enum MapTransition {
    /// The new picture replaces the old at once: the window was resized.
    case none
    /// The marks pop up one after another: the first picture of a scan.
    case popIn
    /// The old marks shrink away, then the new ones pop up: another view, another disk.
    case swap
    /// Marks that stand for the same thing move from their old place to their new one:
    /// going into a folder, coming back out, or the same folder with new numbers.
    case morph(Morph)

    var duration: Double {
        switch self {
        case .none, .popIn: return 0
        case .swap: return Swap.duration
        case .morph(let morph): return morph.anchor == nil ? 0.5 : 0.62
        }
    }
}

/// Timing of `MapTransition.swap`.
enum Swap {
    /// The old picture is gone by then.
    static let duration = 0.46
    /// When the new picture starts to pop up.
    static let arrival = 0.2

    /// 1…0 as the `order`-th old mark shrinks away, `elapsed` seconds in.
    static func leaving(_ order: Int, elapsed: Double) -> Double {
        let start = Double(min(order, 30)) * 0.007
        let t = min(max((elapsed - start) / 0.25, 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }
}

/// A transition under way: what it is, when it began, and what the picture being left looked
/// like at that moment.
struct ActiveTransition {
    var kind: MapTransition
    var start: Date
    /// The picture being left, for `swap`. A morph carries both pictures itself.
    var previous: MapScene?
    /// How far each mark of the picture being left was lifted by the pointer.
    var lifts: [Int: Double]
    /// The flow bar whose family was kept bright.
    var flowFocus: Int?

    /// 0…1, eased at both ends.
    func progress(at date: Date) -> Double {
        let t = min(max(date.timeIntervalSince(start) / kind.duration, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    func isOver(at date: Date) -> Bool {
        date.timeIntervalSince(start) >= kind.duration
    }
}
