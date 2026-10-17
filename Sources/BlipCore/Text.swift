/// Text helpers shared by the CLI and the renderer.
public enum CardText {
    /// Collapses every run of whitespace, line breaks included, to one space, drops other control
    /// characters, and trims both ends.
    public static func normalize(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = true
            } else if !character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }

    /// Cuts `text` to at most `limit` user-perceived characters, ending in a single ellipsis when
    /// it was cut. Emoji, flags and combining sequences are never split.
    public static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return String(text.prefix(limit)) }
        var kept = text.prefix(limit - 1)
        while kept.last?.isWhitespace == true { kept.removeLast() }
        return String(kept) + "…"
    }

    /// Cuts `text` to the most user-perceived characters that fit in `width` points with a single
    /// ellipsis after them, or returns it whole when it fits. A word too long for the line is cut
    /// inside, like any other text. `measure` gives a string's drawn width.
    public static func fit(_ text: String, width: Double, measure: (String) -> Double) -> String {
        guard measure(text) > width else { return text }
        let characters = Array(text)
        func cut(_ count: Int) -> String {
            var kept = characters[..<count]
            while kept.last?.isWhitespace == true { kept.removeLast() }
            return String(kept) + "…"
        }
        // The most characters that still fit with the ellipsis; the ellipsis alone if none do.
        var low = 0, high = characters.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if measure(cut(middle)) <= width { low = middle } else { high = middle - 1 }
        }
        return cut(low)
    }

    /// Normalizes and truncates a card's line; nil when nothing is left.
    public static func line(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let line = truncate(normalize(text), limit: limit)
        return line.isEmpty ? nil : line
    }

    /// Splits text read from stdin: the first non-empty line is the title and the remaining lines,
    /// joined with a space, are the detail.
    public static func splitStandardInput(_ text: String) -> (title: String?, detail: String?) {
        let lines = text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !normalize($0).isEmpty }
        let detail = lines.dropFirst().joined(separator: " ")
        return (lines.first, detail.isEmpty ? nil : detail)
    }

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
