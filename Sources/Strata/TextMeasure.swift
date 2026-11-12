import AppKit
import CoreText

/// Measures and shortens labels with Core Text, so layouts can be prepared off the main thread.
enum TextMeasure {
    static func font(size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    static func width(_ text: String, size: CGFloat, bold: Bool) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font(size: size, bold: bold)])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
    }

    /// The text itself when it fits, a version ending in an ellipsis when part of it does,
    /// nil when not even two characters fit.
    static func fitted(_ text: String, width available: CGFloat, size: CGFloat, bold: Bool) -> String? {
        if width(text, size: size, bold: bold) <= available { return text }
        let characters = Array(text)
        var low = 0, high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if width(String(characters[..<middle]) + "…", size: size, bold: bold) <= available { low = middle } else { high = middle - 1 }
        }
        return low >= 2 ? String(characters[..<low]) + "…" : nil
    }
}

/// A name and a size prepared for one mark: what to write and how large.
struct MarkLabel: Sendable {
    var name: String
    var size: String?
    var fontSize: CGFloat
}
