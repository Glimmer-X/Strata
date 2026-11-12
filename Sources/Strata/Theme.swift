import SwiftUI

/// A colour in OKLCH: lightness 0…1, chroma, hue in degrees. Working in this space keeps
/// steps of lightness even to the eye, which is what lets one hue family carry a whole map.
struct OKColor: Hashable {
    var l: Double
    var c: Double
    var h: Double

    func lighter(_ amount: Double) -> OKColor {
        OKColor(l: min(max(l + amount, 0.05), 0.98), c: c, h: h)
    }

    var color: Color {
        let radians = h * .pi / 180
        let a = c * cos(radians), b = c * sin(radians)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l_ * l_ * l_, m3 = m_ * m_ * m_, s3 = s_ * s_ * s_
        func encode(_ linear: Double) -> Double {
            let v = min(max(linear, 0), 1)
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return Color(.sRGB,
                     red: encode(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
                     green: encode(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
                     blue: encode(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3))
    }
}

/// Which colour a mark gets, independent of the theme: a slot of the theme's family plus a
/// small shift. Marks deeper in a folder keep their ancestor's slot and shift only slightly,
/// so a folder reads as one colour with a quiet texture inside.
struct Tone: Hashable {
    enum Role: Hashable { case family(Int), neutral, hidden, free }
    var role: Role
    var lightness: Double = 0
    var hue: Double = 0
    /// Multiplier on the colourfulness; below 1 for marks that should recede.
    var chroma: Double = 1

    func shifted(lightness: Double, hue: Double = 0, chroma: Double = 1) -> Tone {
        Tone(role: role, lightness: self.lightness + lightness, hue: self.hue + hue, chroma: self.chroma * chroma)
    }
}

/// One colour scheme. Every theme is a single family: neighbouring hues at different
/// depths of light, plus one accent used for highlights.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: LocalizedStringKey
    let isDark: Bool
    let background: OKColor
    /// The family, ordered so that neighbours in the list contrast well.
    let tones: [OKColor]
    let neutral: OKColor
    let hidden: OKColor
    let accent: OKColor
    let text: OKColor
    let secondaryText: OKColor

    static func == (lhs: Theme, rhs: Theme) -> Bool { lhs.id == rhs.id }

    func fill(_ tone: Tone) -> OKColor {
        var base: OKColor
        switch tone.role {
        case .family(let index): base = tones[index % tones.count]
        case .neutral: base = neutral
        case .hidden: base = hidden
        case .free: base = background
        }
        base.l = min(max(base.l + tone.lightness, 0.08), 0.96)
        base.h += tone.hue
        base.c *= tone.chroma
        return base
    }

    /// The colour of a folder's own body, seen as the thin wall between the cells inside it.
    func wall(_ tone: Tone) -> OKColor {
        let base = fill(tone)
        return OKColor(l: base.l + (isDark ? -0.075 : -0.07), c: base.c * 0.9, h: base.h)
    }

    /// Text colour that reads on a fill.
    func ink(on fill: OKColor) -> OKColor {
        fill.l > 0.63 ? OKColor(l: 0.2, c: min(fill.c, 0.03), h: fill.h) : OKColor(l: 0.97, c: 0.01, h: fill.h)
    }

    var line: OKColor { isDark ? text : secondaryText }

    static let abyss = Theme(
        id: "abyss", name: "深海", isDark: true,
        background: OKColor(l: 0.215, c: 0.035, h: 252),
        tones: [
            OKColor(l: 0.70, c: 0.062, h: 238), OKColor(l: 0.45, c: 0.085, h: 254),
            OKColor(l: 0.58, c: 0.075, h: 245), OKColor(l: 0.36, c: 0.070, h: 258),
            OKColor(l: 0.79, c: 0.042, h: 232), OKColor(l: 0.52, c: 0.055, h: 222),
        ],
        neutral: OKColor(l: 0.33, c: 0.030, h: 252), hidden: OKColor(l: 0.285, c: 0.028, h: 252),
        accent: OKColor(l: 0.91, c: 0.035, h: 80),
        text: OKColor(l: 0.95, c: 0.012, h: 240), secondaryText: OKColor(l: 0.72, c: 0.03, h: 245))

    static let frost = Theme(
        id: "frost", name: "霜", isDark: false,
        background: OKColor(l: 0.957, c: 0.008, h: 235),
        tones: [
            OKColor(l: 0.43, c: 0.072, h: 246), OKColor(l: 0.67, c: 0.055, h: 226),
            OKColor(l: 0.53, c: 0.075, h: 236), OKColor(l: 0.79, c: 0.040, h: 216),
            OKColor(l: 0.36, c: 0.062, h: 256), OKColor(l: 0.61, c: 0.050, h: 202),
        ],
        neutral: OKColor(l: 0.875, c: 0.012, h: 235), hidden: OKColor(l: 0.835, c: 0.014, h: 235),
        accent: OKColor(l: 0.60, c: 0.15, h: 40),
        text: OKColor(l: 0.24, c: 0.020, h: 250), secondaryText: OKColor(l: 0.48, c: 0.020, h: 245))

    static let moss = Theme(
        id: "moss", name: "苔原", isDark: true,
        background: OKColor(l: 0.215, c: 0.020, h: 165),
        tones: [
            OKColor(l: 0.71, c: 0.062, h: 150), OKColor(l: 0.45, c: 0.062, h: 168),
            OKColor(l: 0.58, c: 0.070, h: 142), OKColor(l: 0.36, c: 0.048, h: 174),
            OKColor(l: 0.80, c: 0.048, h: 132), OKColor(l: 0.52, c: 0.042, h: 188),
        ],
        neutral: OKColor(l: 0.33, c: 0.020, h: 165), hidden: OKColor(l: 0.285, c: 0.018, h: 165),
        accent: OKColor(l: 0.92, c: 0.055, h: 100),
        text: OKColor(l: 0.95, c: 0.012, h: 150), secondaryText: OKColor(l: 0.72, c: 0.025, h: 155))

    static let dusk = Theme(
        id: "dusk", name: "暮色", isDark: true,
        background: OKColor(l: 0.215, c: 0.022, h: 30),
        tones: [
            OKColor(l: 0.71, c: 0.085, h: 48), OKColor(l: 0.46, c: 0.090, h: 28),
            OKColor(l: 0.59, c: 0.095, h: 60), OKColor(l: 0.37, c: 0.065, h: 18),
            OKColor(l: 0.80, c: 0.060, h: 76), OKColor(l: 0.53, c: 0.060, h: 5),
        ],
        neutral: OKColor(l: 0.33, c: 0.022, h: 30), hidden: OKColor(l: 0.285, c: 0.020, h: 30),
        accent: OKColor(l: 0.93, c: 0.030, h: 95),
        text: OKColor(l: 0.95, c: 0.012, h: 60), secondaryText: OKColor(l: 0.73, c: 0.028, h: 50))

    static let all: [Theme] = [.abyss, .frost, .moss, .dusk]

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .abyss
    }
}
