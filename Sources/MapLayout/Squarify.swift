import CoreGraphics

/// The classic squarified treemap: fills a rectangle with one rectangle per value, areas in
/// proportion, keeping them close to square. Used to seed the bubble layout, which is why
/// the result follows the input order: first values end up at the top left.
public enum Squarify {
    public static func rects(values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else {
            return values.map { _ in CGRect(origin: rect.origin, size: .zero) }
        }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { max($0 * scale, 1e-9) }

        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = rect
        var row: [Int] = []
        var rowArea = 0.0

        // Worst aspect ratio in a row of the given areas laid along a side of this length.
        func worst(_ indices: [Int], _ sum: Double, side: Double) -> Double {
            guard !indices.isEmpty, sum > 0 else { return .infinity }
            let thickness = sum / side
            var ratio = 0.0
            for index in indices {
                let length = areas[index] / thickness
                ratio = max(ratio, max(length / thickness, thickness / length))
            }
            return ratio
        }

        func flush() {
            guard !row.isEmpty else { return }
            let horizontal = remaining.width >= remaining.height   // the row runs along the short side
            let side = Double(horizontal ? remaining.height : remaining.width)
            let thickness = rowArea / side
            var offset = 0.0
            for index in row {
                let length = areas[index] / thickness
                result[index] = horizontal
                    ? CGRect(x: Double(remaining.minX), y: Double(remaining.minY) + offset, width: thickness, height: length)
                    : CGRect(x: Double(remaining.minX) + offset, y: Double(remaining.minY), width: length, height: thickness)
                offset += length
            }
            if horizontal {
                remaining = CGRect(x: Double(remaining.minX) + thickness, y: Double(remaining.minY),
                                   width: max(0, Double(remaining.width) - thickness), height: Double(remaining.height))
            } else {
                remaining = CGRect(x: Double(remaining.minX), y: Double(remaining.minY) + thickness,
                                   width: Double(remaining.width), height: max(0, Double(remaining.height) - thickness))
            }
            row.removeAll(keepingCapacity: true)
            rowArea = 0
        }

        for index in areas.indices {
            let side = Double(min(remaining.width, remaining.height))
            if !row.isEmpty, worst(row + [index], rowArea + areas[index], side: side) > worst(row, rowArea, side: side) {
                flush()
            }
            row.append(index)
            rowArea += areas[index]
        }
        flush()
        return result
    }
}
