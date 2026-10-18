/// Text helpers shared by the CLI and the renderer.
public enum CardText {
    /// Collapses every run of whitespace, line breaks included, to one space, drops terminal escape
    /// sequences (the colors of piped command output), other control characters and the bidi
    /// embedding, override and isolate controls, which could reorder a card's or a history line's
    /// text, and trims both ends.
    public static func normalize(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in withoutEscapeSequences(text) {
            if character.isWhitespace {
                pendingSpace = true
            } else if !character.unicodeScalars.allSatisfy({
                $0.properties.generalCategory == .control || (0x202A...0x202E).contains($0.value)
                    || (0x2066...0x2069).contains($0.value)
            }) {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }

    /// `text` without ANSI escape sequences: CSI sequences such as colors (`ESC [ 31 m`, or the
    /// one-character CSI), OSC sequences such as terminal titles and hyperlinks (up to BEL or
    /// `ESC \`), and two-character escapes. A sequence that never ends is not one: its text stays,
    /// so a part of the text cannot hide the rest.
    static func withoutEscapeSequences(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { $0 == "\u{1B}" || $0 == "\u{9B}" || $0 == "\u{9D}" }) else { return text }
        // Just past the final byte of a CSI sequence whose parameters start at `start`: parameter
        // and intermediate bytes, then one final byte.
        func endOfSequence(from start: Int) -> Int? {
            var index = start
            while index < scalars.count, (0x20...0x3F).contains(scalars[index].value) { index += 1 }
            guard index < scalars.count, (0x40...0x7E).contains(scalars[index].value) else { return nil }
            return index + 1
        }
        // Once a search for an OSC terminator fails, every later one would too: remembering it
        // keeps a long text full of unfinished sequences linear.
        var commandsEnd = true
        // Just past the terminator of an OSC sequence whose text starts at `start`.
        func endOfCommand(from start: Int) -> Int? {
            guard commandsEnd else { return nil }
            var index = start
            while index < scalars.count {
                switch scalars[index] {
                case "\u{07}", "\u{9C}": return index + 1
                case "\u{1B}" where index + 1 < scalars.count && scalars[index + 1] == "\\": return index + 2
                default: index += 1
                }
            }
            commandsEnd = false
            return nil
        }
        var kept = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            var end: Int?
            switch scalar {
            case "\u{9B}": end = endOfSequence(from: index + 1)
            case "\u{9D}": end = endOfCommand(from: index + 1)
            case "\u{1B}" where index + 1 < scalars.count:
                switch scalars[index + 1] {
                case "[": end = endOfSequence(from: index + 2)
                case "]": end = endOfCommand(from: index + 2)
                default: end = index + 2
                }
            default: break
            }
            if let end {
                index = end
            } else {
                // Not a sequence; a lone ESC goes with the other control characters.
                kept.append(scalar)
                index += 1
            }
        }
        return String(kept)
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

    /// Breaks `text` into at most `maxLines` lines, each no wider than `width` points. Text that fits
    /// on one line comes back whole, so the wrap starts exactly where `fit` would cut. When text is
    /// left over for the last line, it is cut with `fit` and ends in an ellipsis. The spaces at a
    /// break are dropped.
    ///
    /// - Parameters:
    ///   - measure: A string's drawn width.
    ///   - lineBreak: How many characters of a text too wide for the line go on it, such as a
    ///     typesetter's choice. A choice that does not fit by `measure` is shortened to the last
    ///     break before it. Without one, lines break after spaces and next to ideographs, and inside
    ///     a word too long for a line.
    public static func wrap(
        _ text: String, width: Double, maxLines: Int, measure: (String) -> Double,
        lineBreak: ((String) -> Int)? = nil
    ) -> [String] {
        let maxLines = max(maxLines, 1)
        var lines: [String] = []
        var rest = Substring(text)
        while lines.count < maxLines {
            rest = rest.drop(while: \.isWhitespace)
            let remaining = String(rest)
            if remaining.isEmpty, !lines.isEmpty { break }
            if lines.count == maxLines - 1 || measure(remaining) <= width {
                lines.append(fit(remaining, width: width, measure: measure))
                break
            }
            let characters = Array(remaining)
            var count = min(max(lineBreak?(remaining) ?? widestBreak(characters, width: width, measure: measure), 1),
                            characters.count)
            while count > 1, measure(prefix(characters, count)) > width {
                count = (1..<count).last { canBreak(characters, before: $0) } ?? count - 1
            }
            lines.append(prefix(characters, count))
            rest = rest.dropFirst(count)
        }
        return lines
    }

    /// The most characters of `characters` that fit in `width`, ending at the last break inside
    /// them; inside a word when the first word alone is too wide.
    private static func widestBreak(_ characters: [Character], width: Double, measure: (String) -> Double) -> Int {
        var low = 1, high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if measure(prefix(characters, middle)) <= width { low = middle } else { high = middle - 1 }
        }
        if low < characters.count, canBreak(characters, before: low) { return low }
        return (1..<low).last { canBreak(characters, before: $0) } ?? low
    }

    /// The first `count` characters as a line, without the spaces it ends in.
    private static func prefix(_ characters: [Character], _ count: Int) -> String {
        var kept = characters[..<count]
        while kept.last?.isWhitespace == true { kept.removeLast() }
        return String(kept)
    }

    /// Whether a line may end before `characters[index]`: after a space, or next to an ideograph or
    /// kana, though never before closing punctuation or after opening punctuation.
    static func canBreak(_ characters: [Character], before index: Int) -> Bool {
        guard index > 0, index < characters.count else { return false }
        let before = characters[index - 1], after = characters[index]
        if before.isWhitespace { return !after.isWhitespace }
        if after.isWhitespace { return false }
        let closing: Set<Unicode.GeneralCategory> = [.closePunctuation, .finalPunctuation, .otherPunctuation]
        let opening: Set<Unicode.GeneralCategory> = [.openPunctuation, .initialPunctuation]
        if let first = after.unicodeScalars.first, closing.contains(first.properties.generalCategory) { return false }
        if let last = before.unicodeScalars.last, opening.contains(last.properties.generalCategory) { return false }
        return isIdeographic(before) || isIdeographic(after)
    }

    /// Han ideographs and Japanese kana, which break between any two of them.
    private static func isIdeographic(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x31F0...0x31FF, // Katakana phonetic extensions
             0xFF66...0xFF9F: // Halfwidth Katakana
            return true
        default:
            return scalar.properties.isIdeographic
        }
    }

    /// How many whole characters of `text` lie within its first `utf16Length` UTF-16 code units, as
    /// Core Text counts.
    public static func characterCount(_ text: String, utf16Length: Int) -> Int {
        var count = 0, length = 0
        for character in text {
            length += character.utf16.count
            if length > utf16Length { break }
            count += 1
        }
        return count
    }

    /// What VoiceOver reads for a card: the whole title, then the whole detail, however they wrap.
    public static func spoken(title: String, detail: String?) -> String {
        [title, detail].compactMap { $0 }.joined(separator: ", ")
    }

    /// Normalizes a card's line, cut to `limit` characters when one is given; nil when nothing is
    /// left. The title and the detail have no limit: the card wraps them to its lines.
    public static func line(_ text: String?, limit: Int? = nil) -> String? {
        guard let text else { return nil }
        let normalized = normalize(text)
        let line = limit.map { truncate(normalized, limit: $0) } ?? normalized
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
