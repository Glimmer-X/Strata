import SwiftUI

/// What a drawing pass needs besides the scene.
struct MapFrame {
    var theme: Theme
    var lift: (Int) -> Double
    /// 0 for a mark not shown yet (or gone), 1 when fully there; springs past 1 on the way in.
    var appear: (Int) -> Double
    /// How small a mark is drawn at `appear` 0. Popping up starts close to full size, so the
    /// spring reads as a wobble; shrinking away goes much further.
    var smallest = 0.74
    /// Opacity per unit of `appear`: above 1 a mark is solid before it is full size.
    var solidity = 1.5

    /// A picture whose marks shrink away one after another, `elapsed` seconds in.
    static func leaving(_ theme: Theme, elapsed: Double) -> MapFrame {
        MapFrame(theme: theme, lift: { _ in 0 }, appear: { Swap.leaving($0, elapsed: elapsed) }, smallest: 0.3, solidity: 1.15)
    }
}

extension MapScene {
    func draw(frame: MapFrame, flowFocus: Int?, in context: GraphicsContext) {
        switch self {
        case .bubbles(let scene): BubbleRenderer.draw(scene, frame: frame, in: context)
        case .flow(let scene): FlowRenderer.draw(scene, frame: frame, focus: flowFocus, in: context)
        }
    }
}

/// Free space is an empty cell: a quiet outline holding a sparse field of dots.
func drawFree(_ shape: Path, dots: Path?, transform: CGAffineTransform, theme: Theme, in context: GraphicsContext) {
    let line = theme.line.color
    context.stroke(shape.applying(transform), with: .color(line.opacity(0.42)), lineWidth: 1.2)
    if let dots { context.fill(dots.applying(transform), with: .color(line.opacity(0.26))) }
}

func scale(about point: CGPoint, by factor: Double) -> CGAffineTransform {
    CGAffineTransform(translationX: point.x, y: point.y)
        .scaledBy(x: factor, y: factor)
        .translatedBy(x: -point.x, y: -point.y)
}

func unit(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

func draw(_ label: MarkLabel?, at point: CGPoint, ink: Color, opacity: Double, in context: GraphicsContext) {
    guard let label, opacity > 0.02 else { return }
    var layer = context
    layer.opacity = context.opacity * opacity
    let name = Text(label.name).font(.system(size: label.fontSize, weight: .semibold)).foregroundStyle(ink)
    if let size = label.size {
        layer.draw(name, at: CGPoint(x: point.x, y: point.y - label.fontSize * 0.58), anchor: .center)
        layer.draw(Text(size).font(.system(size: label.fontSize - 1)).foregroundStyle(ink.opacity(0.78)),
                   at: CGPoint(x: point.x, y: point.y + label.fontSize * 0.74), anchor: .center)
    } else {
        layer.draw(name, at: point, anchor: .center)
    }
}

/// Draws the bubble view: up to three levels of bubbles, each level closer together and
/// closer in colour than the one outside it. A bubble under the pointer swells, its inner
/// bubbles move apart and show their names.
enum BubbleRenderer {
    static func draw(_ scene: BubbleScene, frame: MapFrame, in context: GraphicsContext) {
        let theme = frame.theme
        var transforms: [Int: CGAffineTransform] = [:]

        for (order, index) in scene.top.enumerated() {
            let cell = scene.cells[index]
            let appear = frame.appear(order)
            guard appear > 0.001 else { continue }
            let lift = frame.lift(index)
            let outer = scale(about: cell.center, by: (frame.smallest + (1 - frame.smallest) * appear) * (1 + 0.02 * lift))
            transforms[index] = outer
            var layer = context
            layer.opacity = unit(appear * frame.solidity)

            if cell.item.kind == .free {
                drawFree(cell.outline, dots: cell.dots, transform: outer, theme: theme, in: layer)
                continue
            }

            let fill = theme.fill(cell.tone)
            if cell.children.isEmpty {
                layer.fill(cell.outline.applying(outer), with: .color(fill.lighter(0.03 * unit(lift)).color))
                if cell.item.kind == .hidden || cell.item.kind == .unscanned {
                    layer.stroke(cell.outline.applying(outer), with: .color(theme.line.color.opacity(0.28)),
                                 style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                } else if lift > 0.02 {
                    layer.stroke(cell.outline.applying(outer), with: .color(theme.accent.color.opacity(unit(lift))), lineWidth: 1.5)
                }
                continue
            }

            layer.fill(cell.outline.applying(outer), with: .color(theme.wall(cell.tone).color))
            for childIndex in cell.children {
                let child = scene.cells[childIndex]
                let childLift = frame.lift(childIndex)
                // The parent's swelling pushes its children apart; the one under the pointer pops back out.
                let middle = scale(about: child.center, by: 1 - 0.035 * unit(lift) + 0.055 * childLift).concatenating(outer)
                transforms[childIndex] = middle
                layer.fill(child.outline.applying(middle), with: .color(theme.fill(child.tone).lighter(0.035 * unit(childLift)).color))
                for grandIndex in child.children {
                    let grand = scene.cells[grandIndex]
                    let inner = scale(about: grand.center, by: 1 - 0.07 * unit(childLift)).concatenating(middle)
                    transforms[grandIndex] = inner
                    layer.fill(grand.outline.applying(inner), with: .color(theme.fill(grand.tone).color))
                }
                if childLift > 0.02 {
                    layer.stroke(child.outline.applying(middle), with: .color(theme.accent.color.opacity(unit(childLift))), lineWidth: 1.5)
                }
            }
        }

        // Names go on top of every fill.
        for (order, index) in scene.top.enumerated() {
            guard let outer = transforms[index] else { continue }
            let cell = scene.cells[index]
            var layer = context
            layer.opacity = unit(frame.appear(order) * frame.solidity)
            let lift = unit(frame.lift(index))
            let at = cell.center.applying(outer)

            switch cell.item.kind {
            case .free:
                BubbleRenderer.draw(cell.label, at: at, ink: theme.text.color, opacity: 1, in: layer)
                continue
            case .hidden, .unscanned:
                BubbleRenderer.draw(cell.label, at: at, ink: theme.secondaryText.color, opacity: 1, in: layer)
                continue
            default: break
            }

            let opensUp = cell.children.contains { scene.cells[$0].label != nil }
            let ink = theme.ink(on: cell.children.isEmpty ? theme.fill(cell.tone) : theme.fill(scene.cells[cell.children[0]].tone))
            BubbleRenderer.draw(cell.label, at: at, ink: ink.color, opacity: opensUp ? 1 - lift : 1, in: layer)
            guard lift > 0.02 else { continue }

            for childIndex in cell.children {
                guard let middle = transforms[childIndex] else { continue }
                let child = scene.cells[childIndex]
                let childLift = unit(frame.lift(childIndex))
                let showsInside = child.children.contains { scene.cells[$0].label != nil }
                BubbleRenderer.draw(child.label, at: child.center.applying(middle), ink: theme.ink(on: theme.fill(child.tone)).color,
                                    opacity: lift * (showsInside ? 1 - childLift : 1), in: layer)
                guard childLift > 0.02 else { continue }
                for grandIndex in child.children {
                    guard let inner = transforms[grandIndex] else { continue }
                    let grand = scene.cells[grandIndex]
                    BubbleRenderer.draw(grand.label, at: grand.center.applying(inner), ink: theme.ink(on: theme.fill(grand.tone)).color,
                                        opacity: childLift, in: layer)
                }
            }
        }
    }

    private static func draw(_ label: MarkLabel?, at point: CGPoint, ink: Color, opacity: Double, in context: GraphicsContext) {
        Strata.draw(label, at: point, ink: ink, opacity: opacity, in: context)
    }
}

/// Draws the flow view: rows of bars joined by ribbons. The bar under the pointer bounces
/// and everything it belongs to and contains stays bright while the rest steps back.
enum FlowRenderer {
    static func draw(_ scene: FlowScene, frame: MapFrame, focus: Int?, in context: GraphicsContext) {
        let theme = frame.theme
        let strength = focus.map { unit(frame.lift($0)) } ?? 0
        let family = focus.map { scene.family(of: $0) } ?? []
        func presence(_ bar: Int) -> Double {
            family.isEmpty || family.contains(bar) ? 1 : 1 - 0.55 * strength
        }

        for ribbon in scene.ribbons {
            let appear = unit(frame.appear(scene.bars[ribbon.child].level * 4) * frame.solidity * 0.93)
            guard appear > 0.01 else { continue }
            let tone = scene.bars[ribbon.child].tone
            let color = tone.role == .free || tone.role == .hidden ? theme.neutral : theme.fill(tone)
            let related = family.contains(ribbon.parent) && family.contains(ribbon.child)
            let opacity = (0.4 + (related ? 0.3 * strength : 0)) * min(presence(ribbon.parent), presence(ribbon.child))
            context.fill(ribbon.path, with: .color(color.color.opacity(opacity * appear)))
        }

        for (index, bar) in scene.bars.enumerated() {
            let appear = frame.appear(bar.level * 4)
            guard appear > 0.001 else { continue }
            let lift = frame.lift(index)
            let center = CGPoint(x: bar.rect.midX, y: bar.rect.midY)
            // Bars grow mostly in height; the x-scale only follows when shrinking away.
            let tall = max(0.1, 1 - (1 - frame.smallest) * 1.7)
            let wide = frame.smallest < 0.5 ? 0.7 + 0.3 * appear : 1
            let stretch = CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: wide * (1 + 0.012 * lift), y: (tall + (1 - tall) * appear) * (1 + 0.07 * lift))
                .translatedBy(x: -center.x, y: -center.y)
            let radius = min(9, bar.rect.width / 2.4, bar.rect.height / 2.4)
            let shape = Path(roundedRect: bar.rect, cornerRadius: radius, style: .continuous).applying(stretch)
            var layer = context
            layer.opacity = unit(appear * frame.solidity) * presence(index)

            switch bar.item.kind {
            case .free:
                drawFree(Path(roundedRect: bar.rect, cornerRadius: radius, style: .continuous), dots: bar.dots,
                         transform: stretch, theme: theme, in: layer)
                Strata.draw(bar.label, at: center, ink: theme.text.color, opacity: 1, in: layer)
            default:
                let fill = theme.fill(bar.tone)
                layer.fill(shape, with: .color(fill.lighter(0.03 * unit(lift)).color))
                if lift > 0.02 {
                    layer.stroke(shape, with: .color(theme.accent.color.opacity(unit(lift))), lineWidth: 1.5)
                }
                if bar.item.kind == .hidden || bar.item.kind == .unscanned {
                    layer.stroke(shape, with: .color(theme.line.color.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                let ink = bar.item.kind == .hidden || bar.item.kind == .unscanned ? theme.secondaryText : theme.ink(on: fill)
                Strata.draw(bar.label, at: center, ink: ink.color, opacity: 1, in: layer)
            }
        }
    }
}
