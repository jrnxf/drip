#if canImport(AppKit)
import AppKit
import BlipCore
import CoreText

/// Breaks a card's title or detail into lines for the panel and the island, with Core Text choosing
/// where each line ends, so words in every script break where a reader expects: between Japanese or
/// Chinese characters, at Thai word boundaries, after spaces elsewhere.
enum CardLines {
    /// The lines of `text` in `attributes`, at most `maxLines`, each no wider than `width` by
    /// `measure`; the last ends in an ellipsis when the text runs on. Text that fits on one line
    /// comes back whole.
    ///
    /// - Parameter measure: A line's drawn width; without one, the width `attributes` give it. Core
    ///   Text breaks lines at `width` less the padding `measure` adds, so its breaks fit as drawn.
    static func wrap(
        _ text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat, maxLines: Int,
        measure: ((String) -> Double)? = nil
    ) -> [String] {
        let natural = { Double(ceil(NSAttributedString(string: $0, attributes: attributes).size().width)) }
        let measure = measure ?? natural
        let breakWidth = Double(width) - max(measure(text) - natural(text), 0)
        return CardText.wrap(text, width: Double(width), maxLines: maxLines, measure: measure) { rest in
            let typeset = CTTypesetterCreateWithAttributedString(
                NSAttributedString(string: rest, attributes: attributes) as CFAttributedString)
            let length = CTTypesetterSuggestLineBreak(typeset, 0, breakWidth)
            return CardText.characterCount(rest, utf16Length: length)
        }
    }
}
#endif
