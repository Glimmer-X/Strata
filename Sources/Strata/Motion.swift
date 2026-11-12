import Foundation

/// A damped spring on one number, tuned to overshoot a little so marks feel like jelly.
struct Spring {
    var value = 0.0
    var velocity = 0.0

    private static let stiffness = 300.0
    private static let damping = 13.0

    mutating func step(toward target: Double, dt: Double) {
        // Small fixed steps keep the integration stable when a frame arrives late.
        var remaining = min(dt, 0.1)
        while remaining > 0 {
            let h = min(remaining, 1.0 / 240)
            let force = Spring.stiffness * (target - value) - Spring.damping * velocity
            velocity += force * h
            value += velocity * h
            remaining -= h
        }
    }

    func isResting(at target: Double) -> Bool {
        abs(value - target) < 0.002 && abs(velocity) < 0.02
    }

    /// The same spring released from 0 towards 1, as a function of time.
    static func response(_ time: Double) -> Double {
        guard time > 0 else { return 0 }
        let omega = stiffness.squareRoot()
        let zeta = damping / (2 * omega)
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * time) * (cos(damped * time) + zeta * omega / damped * sin(damped * time))
    }
}

/// The moving part of a map view: how far each mark is lifted by the pointer, how far along
/// a newly shown picture is in popping up, and the change from one picture to the next.
/// Read while drawing; never observed.
final class MotionState {
    private var lifts: [Int: Spring] = [:]
    private var lastTick: Date?
    /// Marks the pointer is over.
    var targets: Set<Int> = []
    private var appearStart = Date.distantPast
    private(set) var now = Date()
    private(set) var transition: ActiveTransition?

    /// 0 at rest, 1 when fully lifted; goes slightly past both on the way.
    func lift(_ id: Int) -> Double {
        lifts[id]?.value ?? 0
    }

    /// 0…1 (with overshoot) for the mark that appears `order`-th.
    func appear(_ order: Int) -> Double {
        Spring.response(now.timeIntervalSince(appearStart) - Double(min(order, 30)) * 0.022)
    }

    /// Starts showing a new picture. The old picture's lifts go with the transition, which
    /// lets them settle instead of snapping back.
    /// - Parameters:
    ///   - previous: the picture being replaced, needed by `swap`.
    ///   - flowFocus: the flow bar whose family the old picture kept bright.
    func begin(_ kind: MapTransition, from previous: MapScene?, flowFocus: Int? = nil, at date: Date = Date()) {
        let leaving = lifts.mapValues(\.value)
        lifts.removeAll()
        targets.removeAll()
        lastTick = nil
        now = date
        switch kind {
        case .popIn:
            appearStart = date
            transition = nil
        case .none:
            appearStart = .distantPast
            transition = nil
        case .swap:
            appearStart = date.addingTimeInterval(previous == nil ? 0 : Swap.arrival)
            transition = previous.map { ActiveTransition(kind: kind, start: date, previous: $0, lifts: [:]) }
        case .morph:
            appearStart = .distantPast
            transition = ActiveTransition(kind: kind, start: date, previous: nil, lifts: leaving, flowFocus: flowFocus)
        }
    }

    /// Set when a transition has just ended; read once with `takeFinished`.
    private var finished = false

    func takeFinished() -> Bool {
        defer { finished = false }
        return finished
    }

    var isTransitioning: Bool { transition != nil }

    /// Moves everything forward to `date`. Returns false once nothing moves any more.
    func advance(to date: Date) -> Bool {
        let dt = lastTick.map { date.timeIntervalSince($0) } ?? 0
        lastTick = date
        now = date
        for id in targets where lifts[id] == nil { lifts[id] = Spring() }
        var moving = date.timeIntervalSince(appearStart) < 1.6
        if let transition {
            if transition.isOver(at: date) {
                self.transition = nil
                finished = true
            } else {
                moving = true
            }
        }
        for id in Array(lifts.keys) {
            let target = targets.contains(id) ? 1.0 : 0.0
            lifts[id]!.step(toward: target, dt: dt)
            if lifts[id]!.isResting(at: target) {
                if target == 0 { lifts[id] = nil } else { lifts[id]!.value = 1; lifts[id]!.velocity = 0 }
            } else {
                moving = true
            }
        }
        if !moving { lastTick = nil }
        return moving
    }

    /// Jumps to the end of every movement, for still pictures.
    func settle() {
        lifts = Dictionary(uniqueKeysWithValues: targets.map { ($0, Spring(value: 1, velocity: 0)) })
        appearStart = .distantPast
        now = Date()
        lastTick = nil
        transition = nil
    }
}
