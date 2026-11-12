import Foundation

/// How sizes, counts and times are written throughout the app.
enum Format {
    /// "274 GB", "44.8 GB", "512 MB": three significant digits at most, decimal units like the Finder.
    static func size(_ bytes: UInt64) -> String {
        let parts = sizeParts(bytes)
        return "\(parts.number) \(parts.unit)"
    }

    static func sizeParts(_ bytes: UInt64) -> (number: String, unit: String) {
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if bytes < 1000 { return ("\(bytes)", "B") }
        let number: String
        if value >= 99.95 {
            number = String(format: "%.0f", value)
        } else if value >= 9.995 {
            number = String(format: "%.1f", value)
        } else {
            number = String(format: unit == 0 ? "%.0f" : "%.1f", value)
        }
        return (number, units[unit])
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func percent(_ fraction: Double) -> String {
        if fraction < 0.001 { return "<0.1%" }
        return fraction < 0.1 ? String(format: "%.1f%%", fraction * 100) : String(format: "%.0f%%", fraction * 100)
    }

    /// "刚刚扫描", "3 分钟前扫描".
    static func scanned(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return String(localized: "刚刚扫描") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return String(localized: "\(formatter.localizedString(for: date, relativeTo: Date()))扫描")
    }
}
