import CoreGraphics

/// Organic cells that press against each other and fill a region, each with an area in
/// proportion to its size (a Voronoi treemap built on power diagrams).
public enum BubbleLayout {
    /// The power diagram of weighted sites, cut to a convex region. A cell is empty when
    /// its neighbours' weights leave it no room.
    ///
    /// Cell `i` is the set of points `x` with `|x − sᵢ|² − wᵢ ≤ |x − sⱼ|² − wⱼ` for all `j`.
    public static func powerCells(sites: [CGPoint], weights: [Double], in region: Polygon) -> [Polygon] {
        var cells: [Polygon] = []
        cells.reserveCapacity(sites.count)
        for i in sites.indices {
            var cell = region
            let sx = Double(sites[i].x), sy = Double(sites[i].y)
            let own = sx * sx + sy * sy - weights[i]
            for j in sites.indices where j != i && cell.count >= 3 {
                let tx = Double(sites[j].x), ty = Double(sites[j].y)
                cell = Geometry.clip(cell, nx: tx - sx, ny: ty - sy,
                                     c: (tx * tx + ty * ty - weights[j] - own) / 2)
            }
            cells.append(cell)
        }
        return cells
    }

    /// One cell per size, in the same order. Cells are arranged in reading order: the first
    /// sizes end up at the top left, the last at the bottom right, so sorted input gives a
    /// picture where "bigger" also means "earlier".
    ///
    /// - Parameter tolerance: stop once every cell is within this fraction of its target area.
    public static func ordered(sizes: [Double], in region: Polygon, tolerance: Double = 0.01,
                               maximumIterations: Int = 240) -> [Polygon] {
        let count = sizes.count
        let regionArea = Geometry.area(region)
        guard count > 0, regionArea > 0 else { return sizes.map { _ in [] } }
        guard count > 1 else { return [region] }

        // Every cell gets at least a sliver, so even the smallest entry can be seen and hit.
        let total = max(sizes.reduce(0, +), .leastNonzeroMagnitude)
        var shares = sizes.map { max($0 / total, 0.0015) }
        let shareSum = shares.reduce(0, +)
        shares = shares.map { $0 / shareSum }
        let targets = shares.map { $0 * regionArea }

        // Start where a regular treemap would put each cell.
        let box = Geometry.bounds(region)
        let middle = Geometry.centroid(region)
        var sites = Squarify.rects(values: shares, in: box).map { rect -> CGPoint in
            var point = CGPoint(x: rect.midX, y: rect.midY)
            var steps = 0
            while !Geometry.contains(region, point), steps < 24 {
                point = CGPoint(x: point.x + (middle.x - point.x) * 0.15, y: point.y + (middle.y - point.y) * 0.15)
                steps += 1
            }
            return point
        }
        // A weight is a squared radius: two circles with these radii that touch are split
        // exactly where they touch, which makes the target areas a good first guess.
        var weights = targets.map { $0 / Double.pi }

        var best: [Polygon] = []
        var bestError = Double.infinity
        for _ in 0..<maximumIterations {
            let cells = powerCells(sites: sites, weights: weights, in: region)
            var worst = 0.0
            var areas = [Double](repeating: 0, count: count)
            for i in 0..<count {
                areas[i] = Geometry.area(cells[i])
                worst = max(worst, abs(areas[i] - targets[i]) / targets[i])
            }
            if worst < bestError {
                bestError = worst
                best = cells
            }
            if worst < tolerance { break }

            for i in 0..<count {
                if areas[i] > 0 {
                    // Lloyd step: keep the site in the middle of its cell.
                    sites[i] = Geometry.centroid(cells[i])
                }
                // Grow or shrink the squared radius by the area that is missing or in excess.
                weights[i] += (targets[i] - areas[i]) / Double.pi * 0.9
            }
        }
        return best
    }
}
