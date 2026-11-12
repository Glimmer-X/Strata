import CoreGraphics

/// A simple polygon as a list of corners. Everything in this module works on convex ones.
public typealias Polygon = [CGPoint]

public enum Geometry {
    /// Signed area: positive when the corners run counter-clockwise in a y-up system.
    public static func signedArea(_ polygon: Polygon) -> Double {
        var sum = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += Double(a.x * b.y - b.x * a.y)
        }
        return sum / 2
    }

    public static func area(_ polygon: Polygon) -> Double {
        abs(signedArea(polygon))
    }

    public static func centroid(_ polygon: Polygon) -> CGPoint {
        var x = 0.0, y = 0.0, k = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = Double(a.x * b.y - b.x * a.y)
            x += Double(a.x + b.x) * cross
            y += Double(a.y + b.y) * cross
            k += cross * 3
        }
        guard abs(k) > 1e-12 else {
            // Degenerate: fall back to the mean of the corners.
            let count = Double(max(polygon.count, 1))
            return CGPoint(x: polygon.reduce(0) { $0 + Double($1.x) } / count,
                           y: polygon.reduce(0) { $0 + Double($1.y) } / count)
        }
        return CGPoint(x: x / k, y: y / k)
    }

    public static func bounds(_ polygon: Polygon) -> CGRect {
        guard let first = polygon.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in polygon.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether a point lies inside a convex polygon (either winding).
    public static func contains(_ polygon: Polygon, _ point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var sign = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = Double((b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x))
            if abs(cross) < 1e-9 { continue }
            if sign != 0, (cross > 0) != (sign > 0) { return false }
            sign = cross
        }
        return true
    }

    /// The part of a polygon where `nx·x + ny·y ≤ c`.
    public static func clip(_ polygon: Polygon, nx: Double, ny: Double, c: Double) -> Polygon {
        guard polygon.count >= 3 else { return [] }
        var result: Polygon = []
        result.reserveCapacity(polygon.count + 2)
        var previous = polygon[polygon.count - 1]
        var previousSide = nx * Double(previous.x) + ny * Double(previous.y) - c
        for current in polygon {
            let side = nx * Double(current.x) + ny * Double(current.y) - c
            if (side <= 0) != (previousSide <= 0) {
                let t = previousSide / (previousSide - side)
                result.append(CGPoint(x: Double(previous.x) + (Double(current.x) - Double(previous.x)) * t,
                                      y: Double(previous.y) + (Double(current.y) - Double(previous.y)) * t))
            }
            if side <= 0 { result.append(current) }
            previous = current
            previousSide = side
        }
        return result.count >= 3 ? result : []
    }

    /// The part of `subject` inside the convex polygon `clip`, keeping `inset` away from its edges.
    public static func clip(_ subject: Polygon, toConvex clip: Polygon, inset: Double = 0) -> Polygon {
        guard clip.count >= 3 else { return [] }
        let orientation = signedArea(clip) >= 0 ? 1.0 : -1.0
        var result = subject
        for i in clip.indices where result.count >= 3 {
            let a = clip[i], b = clip[(i + 1) % clip.count]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let length = (dx * dx + dy * dy).squareRoot()
            if length < 1e-9 { continue }
            // Outward unit normal of edge a→b.
            let nx = dy / length * orientation, ny = -dx / length * orientation
            result = Geometry.clip(result, nx: nx, ny: ny, c: nx * Double(a.x) + ny * Double(a.y) - inset)
        }
        return result.count >= 3 ? result : []
    }

    /// A convex polygon shrunk by `distance` on every side; empty when nothing is left.
    public static func inset(_ polygon: Polygon, by distance: Double) -> Polygon {
        clip(polygon, toConvex: polygon, inset: distance)
    }

    /// A rounded rectangle as a polygon.
    public static func roundedRect(_ rect: CGRect, radius: Double, steps: Int = 8) -> Polygon {
        let r = min(radius, Double(min(rect.width, rect.height)) / 2)
        let corners: [(Double, Double, Double)] = [
            (Double(rect.maxX) - r, Double(rect.minY) + r, -Double.pi / 2),
            (Double(rect.maxX) - r, Double(rect.maxY) - r, 0),
            (Double(rect.minX) + r, Double(rect.maxY) - r, Double.pi / 2),
            (Double(rect.minX) + r, Double(rect.minY) + r, Double.pi),
        ]
        var points: Polygon = []
        for (cx, cy, start) in corners {
            for step in 0...steps {
                let angle = start + Double.pi / 2 * Double(step) / Double(steps)
                points.append(CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle)))
            }
        }
        return points
    }

    /// Rounds the corners of a polygon by repeatedly cutting them off (Chaikin's scheme),
    /// never cutting more than `cap` from an edge. Gives a pebble-like outline.
    public static func soften(_ polygon: Polygon, cap: Double, passes: Int = 3) -> Polygon {
        var current = polygon
        var limit = cap
        for _ in 0..<passes where current.count >= 3 {
            var next: Polygon = []
            next.reserveCapacity(current.count * 2)
            for i in current.indices {
                let a = current[i], b = current[(i + 1) % current.count]
                let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
                let length = (dx * dx + dy * dy).squareRoot()
                if length < 0.5 {
                    next.append(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                    continue
                }
                let cut = min(length * 0.25, limit) / length
                next.append(CGPoint(x: Double(a.x) + dx * cut, y: Double(a.y) + dy * cut))
                next.append(CGPoint(x: Double(b.x) - dx * cut, y: Double(b.y) - dy * cut))
            }
            current = next
            limit /= 2
        }
        return current
    }

    /// Where the vertical line at `x` crosses a convex polygon.
    public static func verticalSpan(_ polygon: Polygon, x: CGFloat) -> ClosedRange<CGFloat>? {
        horizontalSpan(polygon.map { CGPoint(x: $0.y, y: $0.x) }, y: x)
    }

    /// Where the horizontal line at `y` crosses a convex polygon.
    public static func horizontalSpan(_ polygon: Polygon, y: CGFloat) -> ClosedRange<CGFloat>? {
        var low = CGFloat.infinity, high = -CGFloat.infinity
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if (a.y <= y) == (b.y <= y) { continue }
            let x = a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y)
            low = min(low, x); high = max(high, x)
        }
        return low <= high ? low...high : nil
    }
}
