import SwiftUI

/// What a morph needs to know about a mark, the same for bubbles and bars.
private struct MarkInfo {
    var key: String
    var parent: Int?
    var rect: CGRect
}

private extension MapScene {
    var markInfo: [MarkInfo] {
        switch self {
        case .bubbles(let scene):
            return scene.cells.map { MarkInfo(key: $0.key, parent: $0.parent, rect: $0.outline.boundingRect) }
        case .flow(let scene):
            return scene.bars.map { MarkInfo(key: $0.key, parent: $0.parent, rect: $0.rect) }
        }
    }
}

/// 0 below `from`, 1 above `to`, eased in between.
private func smooth(_ from: Double, _ to: Double, _ x: Double) -> Double {
    let t = min(max((x - from) / (to - from), 0), 1)
    return t * t * (3 - 2 * t)
}

private func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
           width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
}

/// One picture turning into another. A mark that stands for the same thing in both pictures
/// travels from its old place and size to its new ones, the old mark handing over to the new
/// on the way, so the eye can follow every folder through the change.
///
/// When one picture shows a folder inside the other, the outer picture is seen through a
/// camera closing in on that folder's mark, the anchor: everything around it slides out of
/// view while what is inside spreads out to fill the map.
///
/// Everything is described by `q`, 0 showing the outer picture and 1 the inner one. Going in
/// runs `q` from 0 to 1 and coming back out runs it from 1 to 0, so the two are the same
/// movement played forwards and backwards.
struct Morph {
    let outer: MapScene
    let inner: MapScene
    /// Whether the picture being left is `outer`: going in, or new numbers for the same folder.
    let leavesOuter: Bool
    /// The mark of `outer` whose contents `inner` shows, when one folder is inside the other.
    let anchor: Int?
    private let bounds: CGSize
    private let outerMarks: [MarkInfo]
    private let innerMarks: [MarkInfo]
    /// Marks standing for the same thing: outer index → inner index, and back.
    private let outerMatch: [Int: Int]
    private let innerMatch: [Int: Int]
    /// For flow pictures: how far the row under the anchor moves up to become the top row.
    private let rowShift: CGFloat
    /// The anchor and the marks it is inside, which the camera follows.
    private let around: Set<Int>

    init(outer: MapScene, inner: MapScene, leavesOuter: Bool, anchor: Int?, bounds: CGSize) {
        self.outer = outer
        self.inner = inner
        self.leavesOuter = leavesOuter
        self.anchor = anchor
        self.bounds = bounds
        let outerMarks = outer.markInfo, innerMarks = inner.markInfo
        self.outerMarks = outerMarks
        self.innerMarks = innerMarks

        // Only what is inside the anchor can reappear in the inner picture.
        func isInside(_ index: Int) -> Bool {
            guard let anchor else { return true }
            var current = outerMarks[index].parent
            while let step = current {
                if step == anchor { return true }
                current = outerMarks[step].parent
            }
            return false
        }
        var byKey: [String: Int] = [:]
        for index in outerMarks.indices where byKey[outerMarks[index].key] == nil && isInside(index) {
            byKey[outerMarks[index].key] = index
        }
        var outerMatch: [Int: Int] = [:], innerMatch: [Int: Int] = [:]
        for index in innerMarks.indices {
            guard let match = byKey[innerMarks[index].key], outerMatch[match] == nil else { continue }
            outerMatch[match] = index
            innerMatch[index] = match
        }
        self.outerMatch = outerMatch
        self.innerMatch = innerMatch

        var around = Set<Int>()
        var step = anchor
        while let current = step {
            around.insert(current)
            step = outerMarks[current].parent
        }
        self.around = around

        if case .flow = outer, let anchor {
            let top = innerMarks.filter { $0.parent == nil }.map(\.rect.minY).min() ?? 0
            let below = outerMarks.filter { $0.parent == anchor }.map(\.rect.minY).min()
                ?? outerMarks[anchor].rect.maxY + FlowScene.between
            rowShift = top - below
        } else {
            rowShift = 0
        }
    }

    // MARK: Where everything is

    /// How the outer picture is seen: closing in on the anchor until it fills the map.
    private func camera(_ progress: Double) -> CGAffineTransform {
        guard let anchor else { return .identity }
        // The camera leads and the marks settle after it, so the map is never half empty.
        let q = progress * (2 - progress)
        let frame = outerMarks[anchor].rect
        let full = CGRect(origin: .zero, size: bounds)
        switch outer {
        case .bubbles:
            // The scale grows evenly to the eye and the anchor's centre glides to the map's.
            let scale = pow(min(full.width / max(frame.width, 1), full.height / max(frame.height, 1)), q)
            return CGAffineTransform(translationX: -frame.midX, y: -frame.midY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: frame.midX + (full.midX - frame.midX) * q,
                                                 y: frame.midY + (full.midY - frame.midY) * q))
        case .flow:
            // Bars only widen; the row below the anchor rises to the top.
            let scale = pow(full.width / max(frame.width, 1), q)
            return CGAffineTransform(translationX: -frame.midX, y: 0)
                .concatenating(CGAffineTransform(scaleX: scale, y: 1))
                .concatenating(CGAffineTransform(translationX: frame.midX + (full.midX - frame.midX) * q, y: rowShift * q))
        }
    }

    /// Moves a mark drawn at `source` to `target`. Bubbles keep their proportions; bars
    /// take the target's exactly.
    private func fit(_ source: CGRect, into target: CGRect) -> CGAffineTransform {
        switch outer {
        case .bubbles:
            let scale = ((target.width * target.height) / max(source.width * source.height, 1)).squareRoot()
            return CGAffineTransform(translationX: -source.midX, y: -source.midY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: target.midX, y: target.midY))
        case .flow:
            let sx = target.width / max(source.width, 0.5), sy = target.height / max(source.height, 0.5)
            return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: target.minX - source.minX * sx, ty: target.minY - source.minY * sy)
        }
    }

    /// Marks around the anchor make way: they move out from it, faster than the camera alone
    /// would take them, so they leave the map instead of lingering behind the new picture.
    private func push(_ index: Int, view: CGAffineTransform, q: Double) -> CGAffineTransform {
        guard let anchor, !around.contains(index) else { return .identity }
        let from = outerMarks[anchor].rect, mark = outerMarks[index].rect
        let reach = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot() * 0.5 * q * q
        switch outer {
        case .bubbles:
            let a = CGPoint(x: from.midX, y: from.midY).applying(view)
            let b = CGPoint(x: mark.midX, y: mark.midY).applying(view)
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max((dx * dx + dy * dy).squareRoot(), 1)
            return CGAffineTransform(translationX: dx / length * reach, y: dy / length * reach)
        case .flow:
            return CGAffineTransform(translationX: mark.midX < from.midX ? -reach : reach, y: 0)
        }
    }

    /// How many marks of the inner picture continue a mark of the outer one.
    var matchCount: Int { innerMatch.count }

    /// Where every mark of both pictures is drawn and how solid it is, `q` of the way.
    struct Pose {
        var outerPlace: [CGAffineTransform]
        var innerPlace: [CGAffineTransform]
        var outerAlpha: [Double]
        var innerAlpha: [Double]
        /// False for a mark that shares its parent's opacity, and is drawn in one layer with it.
        var outerOwn: [Bool]
        var innerOwn: [Bool]
    }

    func pose(_ q: Double) -> Pose {
        let view = camera(q)
        let back = camera(1).inverted()
        let innerView = back.concatenating(view)
        // How far each new mark has taken over from the old one it replaces.
        let handOver = smooth(0.05, 0.55, q)
        var pose = Pose(outerPlace: [], innerPlace: [], outerAlpha: [], innerAlpha: [], outerOwn: [], innerOwn: [])
        var boxes: [Int: CGRect] = [:]

        for (index, mark) in outerMarks.enumerated() {
            if let match = outerMatch[index] {
                // Moving in the outer picture's own space and then seeing it through the camera
                // keeps what is inside the anchor inside it all the way.
                let box = lerp(mark.rect, innerMarks[match].rect.applying(back), q).applying(view)
                boxes[match] = box
                pose.outerPlace.append(fit(mark.rect, into: box))
                // Stays solid while the new mark fades in over it, so nothing shows through.
                pose.outerAlpha.append(min(1, 2 * (1 - handOver)))
                pose.outerOwn.append(true)
            } else if let parent = mark.parent {
                pose.outerPlace.append(pose.outerPlace[parent])
                pose.outerAlpha.append(pose.outerAlpha[parent])
                pose.outerOwn.append(false)
            } else {
                pose.outerPlace.append(view.concatenating(push(index, view: view, q: q)))
                pose.outerAlpha.append(1 - smooth(0.05, 0.55, q))
                pose.outerOwn.append(true)
            }
        }
        for (index, mark) in innerMarks.enumerated() {
            if let box = boxes[index] {
                pose.innerPlace.append(fit(mark.rect, into: box))
                pose.innerAlpha.append(handOver)
                pose.innerOwn.append(true)
            } else if let parent = mark.parent {
                pose.innerPlace.append(pose.innerPlace[parent])
                pose.innerAlpha.append(pose.innerAlpha[parent])
                pose.innerOwn.append(false)
            } else {
                // New to this picture: grows in place as the rest settles.
                let center = CGPoint(x: mark.rect.midX, y: mark.rect.midY)
                pose.innerPlace.append(scale(about: center, by: 0.7 + 0.3 * q).concatenating(innerView))
                pose.innerAlpha.append(smooth(0.35, 0.9, q))
                pose.innerOwn.append(true)
            }
        }
        return pose
    }

    // MARK: Drawing

    /// Draws the morph `progress` (0…1, eased) of the way from the picture being left.
    /// - Parameters:
    ///   - lifts: how far the pointer had lifted marks of the picture being left; they settle
    ///     back during the first part of the morph instead of snapping.
    ///   - flowFocus: the flow bar whose family the picture being left kept bright.
    func draw(at progress: Double, theme: Theme, lifts: [Int: Double], flowFocus: Int?, in context: GraphicsContext) {
        let q = leavesOuter ? progress : 1 - progress
        let pose = pose(q)
        let settle = 1 - smooth(0, 0.35, progress)
        let leftLift: (Int) -> Double = { (lifts[$0] ?? 0) * settle }
        let still: (Int) -> Double = { _ in 0 }
        let outerLabels = 1 - smooth(0.1, 0.45, q), innerLabels = smooth(0.5, 0.92, q)

        switch (outer, inner) {
        case (.bubbles(let outerScene), .bubbles(let innerScene)):
            MorphRenderer.bubbles(outerScene, place: pose.outerPlace, alpha: pose.outerAlpha, own: pose.outerOwn,
                                  lift: leavesOuter ? leftLift : still, labels: outerLabels, theme: theme, in: context)
            MorphRenderer.bubbles(innerScene, place: pose.innerPlace, alpha: pose.innerAlpha, own: pose.innerOwn,
                                  lift: leavesOuter ? still : leftLift, labels: innerLabels, theme: theme, in: context)
        case (.flow(let outerScene), .flow(let innerScene)):
            MorphRenderer.flow(outerScene, place: pose.outerPlace, alpha: pose.outerAlpha,
                               lift: leavesOuter ? leftLift : still, focus: leavesOuter ? flowFocus : nil,
                               labels: outerLabels, theme: theme, in: context)
            MorphRenderer.flow(innerScene, place: pose.innerPlace, alpha: pose.innerAlpha,
                               lift: leavesOuter ? still : leftLift, focus: leavesOuter ? nil : flowFocus,
                               labels: innerLabels, theme: theme, in: context)
        default:
            break
        }
    }
}

/// Draws one picture of a morph: every mark at its own place and opacity. At `q` 0 or 1 the
/// result is the same as the ordinary renderer's picture at rest.
private enum MorphRenderer {
    static func bubbles(_ scene: BubbleScene, place: [CGAffineTransform], alpha: [Double], own: [Bool],
                        lift: (Int) -> Double, labels: Double, theme: Theme, in context: GraphicsContext) {
        let cells = scene.cells
        guard !cells.isEmpty else { return }

        // The pointer's swelling, as the ordinary renderer applies it, then the morph's move.
        var rests = [CGAffineTransform](repeating: .identity, count: cells.count)
        var transforms = rests
        for (index, cell) in cells.enumerated() {
            if let parent = cell.parent {
                let factor = cell.level == 2
                    ? 1 - 0.035 * unit(lift(parent)) + 0.055 * lift(index)
                    : 1 - 0.07 * unit(lift(parent))
                rests[index] = scale(about: cell.center, by: factor).concatenating(rests[parent])
            } else {
                rests[index] = scale(about: cell.center, by: 1 + 0.02 * lift(index))
            }
            transforms[index] = rests[index].concatenating(place[index])
        }

        // A mark with an opacity of its own is drawn together with the marks inside it that
        // share it, in one layer, so a half-faded parent never shows through its children.
        var group = [Int](repeating: 0, count: cells.count)
        var members: [Int: [Int]] = [:]
        for (index, cell) in cells.enumerated() {
            group[index] = own[index] ? index : group[cell.parent ?? index]
            members[group[index], default: []].append(index)
        }

        func drawCell(_ index: Int, in layer: GraphicsContext) {
            let cell = cells[index]
            let transform = transforms[index]
            if cell.item.kind == .free {
                drawFree(cell.outline, dots: cell.dots, transform: transform, theme: theme, in: layer)
                return
            }
            let shape = cell.outline.applying(transform)
            let raised = unit(lift(index))
            if cell.children.isEmpty {
                layer.fill(shape, with: .color(theme.fill(cell.tone).lighter(0.03 * raised).color))
                if cell.item.kind == .hidden || cell.item.kind == .unscanned {
                    layer.stroke(shape, with: .color(theme.line.color.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    return
                }
            } else {
                layer.fill(shape, with: .color(theme.wall(cell.tone).color))
            }
            if raised > 0.02, cell.children.isEmpty || cell.level > 1 {
                layer.stroke(shape, with: .color(theme.accent.color.opacity(raised)), lineWidth: 1.5)
            }
        }

        for index in cells.indices where own[index] {
            let opacity = alpha[index]
            guard opacity > 0.003, let marks = members[index] else { continue }
            var layer = context
            layer.opacity = opacity
            if marks.count == 1 || opacity > 0.997 {
                for mark in marks { drawCell(mark, in: layer) }
            } else {
                layer.clip(to: Path(cells[index].outline.boundingRect.applying(transforms[index]).insetBy(dx: -12, dy: -12)))
                layer.drawLayer { inner in
                    for mark in marks { drawCell(mark, in: inner) }
                }
            }
        }

        // Names on top, following the same rules as at rest.
        guard labels > 0.01 else { return }
        for index in scene.top {
            let cell = cells[index]
            let opacity = alpha[group[index]] * labels
            guard opacity > 0.01 else { continue }
            var layer = context
            layer.opacity = opacity
            let at = cell.center.applying(transforms[index])
            switch cell.item.kind {
            case .free:
                draw(cell.label, at: at, ink: theme.text.color, opacity: 1, in: layer)
                continue
            case .hidden, .unscanned:
                draw(cell.label, at: at, ink: theme.secondaryText.color, opacity: 1, in: layer)
                continue
            default: break
            }
            let raised = unit(lift(index))
            let opensUp = cell.children.contains { cells[$0].label != nil }
            let ink = theme.ink(on: cell.children.isEmpty ? theme.fill(cell.tone) : theme.fill(cells[cell.children[0]].tone))
            draw(cell.label, at: at, ink: ink.color, opacity: opensUp ? 1 - raised : 1, in: layer)
            guard raised > 0.02 else { continue }
            for childIndex in cell.children {
                let child = cells[childIndex]
                let childRaised = unit(lift(childIndex))
                var childLayer = context
                childLayer.opacity = alpha[group[childIndex]] * labels
                let showsInside = child.children.contains { cells[$0].label != nil }
                draw(child.label, at: child.center.applying(transforms[childIndex]), ink: theme.ink(on: theme.fill(child.tone)).color,
                     opacity: raised * (showsInside ? 1 - childRaised : 1), in: childLayer)
                guard childRaised > 0.02 else { continue }
                for grandIndex in child.children {
                    let grand = cells[grandIndex]
                    var grandLayer = context
                    grandLayer.opacity = alpha[group[grandIndex]] * labels
                    draw(grand.label, at: grand.center.applying(transforms[grandIndex]), ink: theme.ink(on: theme.fill(grand.tone)).color,
                         opacity: childRaised, in: grandLayer)
                }
            }
        }
    }

    static func flow(_ scene: FlowScene, place: [CGAffineTransform], alpha: [Double], lift: (Int) -> Double,
                     focus: Int?, labels: Double, theme: Theme, in context: GraphicsContext) {
        let bars = scene.bars
        guard !bars.isEmpty else { return }
        let strength = focus.map { unit(lift($0)) } ?? 0
        let family = focus.map { scene.family(of: $0) } ?? []
        func presence(_ bar: Int) -> Double {
            family.isEmpty || family.contains(bar) ? 1 : 1 - 0.55 * strength
        }
        let transforms = bars.indices.map { index -> CGAffineTransform in
            let rect = bars[index].rect, raised = lift(index)
            let stretch = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .scaledBy(x: 1 + 0.012 * raised, y: 1 + 0.07 * raised)
                .translatedBy(x: -rect.midX, y: -rect.midY)
            return stretch.concatenating(place[index])
        }

        for ribbon in scene.ribbons {
            let opacity = min(alpha[ribbon.parent], alpha[ribbon.child])
            guard opacity > 0.003 else { continue }
            let up = transforms[ribbon.parent], down = transforms[ribbon.child]
            let topLeft = CGPoint(x: ribbon.top.lowerBound, y: ribbon.topY).applying(up)
            let topRight = CGPoint(x: ribbon.top.upperBound, y: ribbon.topY).applying(up)
            let bottomLeft = CGPoint(x: ribbon.bottom.lowerBound, y: ribbon.bottomY).applying(down)
            let bottomRight = CGPoint(x: ribbon.bottom.upperBound, y: ribbon.bottomY).applying(down)
            guard topRight.x > topLeft.x, bottomRight.x > bottomLeft.x else { continue }
            let path = FlowRibbon.path(top: topLeft.x...topRight.x, topY: topLeft.y,
                                       bottom: bottomLeft.x...bottomRight.x, bottomY: bottomLeft.y)
            let tone = bars[ribbon.child].tone
            let color = tone.role == .free || tone.role == .hidden ? theme.neutral : theme.fill(tone)
            let related = family.contains(ribbon.parent) && family.contains(ribbon.child)
            let strength = (0.4 + (related ? 0.3 * strength : 0)) * min(presence(ribbon.parent), presence(ribbon.child))
            context.fill(path, with: .color(color.color.opacity(strength * opacity)))
        }

        for (index, bar) in bars.enumerated() {
            let opacity = alpha[index] * presence(index)
            guard opacity > 0.003 else { continue }
            let rect = bar.rect.applying(transforms[index])
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            let radius = min(9, rect.width / 2.4, rect.height / 2.4)
            let shape = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            var layer = context
            layer.opacity = opacity
            var labelLayer = context
            labelLayer.opacity = opacity * labels
            let raised = unit(lift(index))

            switch bar.item.kind {
            case .free:
                let original = min(9, bar.rect.width / 2.4, bar.rect.height / 2.4)
                drawFree(Path(roundedRect: bar.rect, cornerRadius: original, style: .continuous), dots: bar.dots,
                         transform: transforms[index], theme: theme, in: layer)
                draw(bar.label, at: center, ink: theme.text.color, opacity: 1, in: labelLayer)
            default:
                let fill = theme.fill(bar.tone)
                layer.fill(shape, with: .color(fill.lighter(0.03 * raised).color))
                if raised > 0.02 {
                    layer.stroke(shape, with: .color(theme.accent.color.opacity(raised)), lineWidth: 1.5)
                }
                let faint = bar.item.kind == .hidden || bar.item.kind == .unscanned
                if faint {
                    layer.stroke(shape, with: .color(theme.line.color.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                draw(bar.label, at: center, ink: (faint ? theme.secondaryText : theme.ink(on: fill)).color, opacity: 1, in: labelLayer)
            }
        }
    }
}
