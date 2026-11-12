import SwiftUI

/// The map itself: draws the current scene and reports what the pointer does on it.
struct MapCanvas: View {
    @ObservedObject var model: AppModel
    /// False for still pictures: draw once, no timeline, no pointer.
    var live: Bool

    var body: some View {
        if live {
            GeometryReader { geometry in
                TimelineView(.animation(paused: !model.animating)) { timeline in
                    Canvas { context, _ in
                        let moving = model.motion.advance(to: timeline.date)
                        paint(in: context)
                        if model.motion.takeFinished() {
                            DispatchQueue.main.async { model.transitionEnded() }
                        }
                        if !moving, model.animating {
                            DispatchQueue.main.async { model.animating = false }
                        }
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): model.pointerMoved(to: location)
                    case .ended: model.pointerMoved(to: nil)
                    }
                }
                .onTapGesture { location in model.clicked(at: location) }
                .contextMenu {
                    if let location = model.pointer.location, let item = model.entry(at: location) {
                        Button("在访达中显示") { model.reveal(item) }
                        Button("移到废纸篓…") { model.trash(item) }
                    }
                }
                .onAppear { model.setMapSize(geometry.size) }
                .onChange(of: geometry.size) { _, size in model.setMapSize(size) }
            }
        } else {
            Canvas { context, _ in paint(in: context) }
        }
    }

    private func paint(in context: GraphicsContext) {
        guard let scene = model.scene else { return }
        let motion = model.motion
        let theme = model.theme
        let live = MapFrame(theme: theme, lift: motion.lift, appear: motion.appear)
        guard let transition = motion.transition else {
            scene.draw(frame: live, flowFocus: model.flowFocus, in: context)
            return
        }
        switch transition.kind {
        case .swap:
            // The old marks shrink away while the new ones start to pop up.
            if let previous = transition.previous {
                let elapsed = motion.now.timeIntervalSince(transition.start)
                previous.draw(frame: .leaving(theme, elapsed: elapsed), flowFocus: nil, in: context)
            }
            scene.draw(frame: live, flowFocus: model.flowFocus, in: context)
        case .morph(let morph):
            morph.draw(at: transition.progress(at: motion.now), theme: theme, lifts: transition.lifts,
                       flowFocus: transition.flowFocus, in: context)
        case .none, .popIn:
            scene.draw(frame: live, flowFocus: model.flowFocus, in: context)
        }
    }
}

/// The small card that follows the pointer over the map.
struct HoverCard: View {
    @ObservedObject var pointer: PointerModel
    let theme: Theme
    let bounds: CGSize

    var body: some View {
        if let info = pointer.info, let location = pointer.location {
            let width: CGFloat = 250
            // Keep the card inside the map: flip to the other side of the pointer near an edge.
            let x = location.x + 18 + width > bounds.width ? location.x - 18 - width : location.x + 18
            let y = min(max(location.y + 14, 0), bounds.height - 86)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(info.size) · \(info.share)").font(.system(size: 12)).monospacedDigit()
                if !info.detail.isEmpty {
                    Text(info.detail).font(.system(size: 11)).lineLimit(2).truncationMode(.middle)
                        .foregroundStyle(theme.secondaryText.color)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(width: width, alignment: .leading)
            .background(theme.background.lighter(theme.isDark ? 0.07 : 0.04).color, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.line.color.opacity(0.18)))
            .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 12, y: 4)
            .offset(x: x, y: y)
            .allowsHitTesting(false)
        }
    }
}
