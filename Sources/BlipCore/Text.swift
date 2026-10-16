/// Text helpers shared by the CLI and the renderer.
public enum CardText {
    /// True when the first strongly directional character of `text` belongs to a right-to-left
    /// script (Hebrew, Arabic and their neighbors), so the line should be right-aligned.
    public static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if isRightToLeftScalar(scalar) { return true }
            if scalar.properties.isAlphabetic { return false }
        }
        return false
    }

    private static func isRightToLeftScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, Arabic Extended
             0xFB1D...0xFDFF, // Hebrew and Arabic presentation forms A
             0xFE70...0xFEFF, // Arabic presentation forms B
             0x10800...0x10FFF, // historic right-to-left scripts
             0x1E800...0x1EFFF: // Mende Kikakui, Adlam, Arabic mathematical symbols
            return scalar.properties.isAlphabetic
        default:
            return false
        }
    }
}
