#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif

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

/// The fill of a card's yes button: the accent, darkened just enough for white text on it.
public struct ButtonPalette: Equatable, Sendable {
    public var fill: SRGBColor

    /// The faintest white checked against the fill, as an opacity over it, so even dimmed text
    /// stays readable.
    public static let faintTextOpacity = 0.85
    /// WCAG AA for normal-size text.
    public static let minimumContrast = 4.5

    /// Darkens `accent` in small steps until both white and white at `faintTextOpacity` reach
    /// `minimumContrast` on it. Dark accents keep a little darkening for depth.
    public init(accent: SRGBColor) {
        var fraction = 0.12
        var fill = accent.mixed(with: .black, fraction)
        while fraction < 1, Self.faintText(on: fill).contrast(with: fill) < Self.minimumContrast {
            fraction += 0.02
            fill = accent.mixed(with: .black, fraction)
        }
        self.fill = fill
    }

    /// White at `faintTextOpacity` as it looks over `background`.
    public static func faintText(on background: SRGBColor) -> SRGBColor {
        background.mixed(with: .white, faintTextOpacity)
    }
}
