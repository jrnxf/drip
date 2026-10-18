import Foundation

/// An sRGB color with components from 0 to 1.
public struct SRGBColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = SRGBColor(red: 1, green: 1, blue: 1)
    public static let black = SRGBColor(red: 0, green: 0, blue: 0)

    /// This color moved `fraction` of the way towards `other`.
    public func mixed(with other: SRGBColor, _ fraction: Double) -> SRGBColor {
        SRGBColor(
            red: red + (other.red - red) * fraction,
            green: green + (other.green - green) * fraction,
            blue: blue + (other.blue - blue) * fraction)
    }

    /// WCAG 2 relative luminance.
    public var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio, from 1 to 21.
    public func contrast(with other: SRGBColor) -> Double {
        let (lighter, darker) = luminance > other.luminance ? (luminance, other.luminance) : (other.luminance, luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// The gradient behind a `wash` card: the accent, darkened just enough for its white text.
public struct WashPalette: Equatable, Sendable {
    /// The lighter, top-leading stop.
    public var top: SRGBColor
    /// The darker, bottom-trailing stop.
    public var bottom: SRGBColor

    /// The detail line's white, as an opacity over the card.
    public static let detailOpacity = 0.85
    /// WCAG AA for normal-size text.
    public static let minimumContrast = 4.5

    /// Darkens `accent` in small steps until both the title (white) and the detail line (white at
    /// `detailOpacity`) reach `minimumContrast` on the lighter stop. Dark accents keep a little
    /// darkening for depth.
    public init(accent: SRGBColor) {
        var fraction = 0.12
        var top = accent.mixed(with: .black, fraction)
        while fraction < 1, Self.detailColor(on: top).contrast(with: top) < Self.minimumContrast {
            fraction += 0.02
            top = accent.mixed(with: .black, fraction)
        }
        self.top = top
        bottom = top.mixed(with: .black, 0.22)
    }

    /// The detail line's color as it looks over `background`.
    public static func detailColor(on background: SRGBColor) -> SRGBColor {
        background.mixed(with: .white, detailOpacity)
    }
}
