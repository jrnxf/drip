import DripCore
import Testing

struct TextTests {
    @Test func normalizeCollapsesWhitespace() {
        #expect(CardText.normalize("  a \t\t b\n\nc\r\nd  ") == "a b c d")
        #expect(CardText.normalize("a\u{00A0}\u{00A0}b") == "a b")
        #expect(CardText.normalize("") == "")
        #expect(CardText.normalize(" \n ") == "")
    }

    @Test func normalizeDropsControlCharacters() {
        #expect(CardText.normalize("a\u{07}b\u{7F}c") == "abc")
    }

    @Test func normalizeDropsEscapeSequences() {
        // The colors of piped command output, such as `cargo build 2>&1 | tail -1 | drip fail`.
        #expect(CardText.normalize("\u{1B}[1;31merror\u{1B}[0m: build failed") == "error: build failed")
        #expect(CardText.normalize("\u{1B}[38;5;208mo\u{1B}[48;2;0;0;0mk\u{1B}[m") == "ok")
        #expect(CardText.normalize("\u{9B}31mred\u{9B}0m") == "red")
        // A terminal title, and a hyperlink ended by BEL and by ESC \.
        #expect(CardText.normalize("\u{1B}]0;title\u{07}text") == "text")
        #expect(CardText.normalize("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\") == "link")
        // Two-character escapes, and a lone ESC at the end.
        #expect(CardText.normalize("a\u{1B}7b\u{1B}8c") == "abc")
        #expect(CardText.normalize("a\u{1B}") == "a")
        // A sequence that never ends is not one, so it cannot hide the text after it.
        #expect(CardText.normalize("\u{1B}]0;evil deploy ok, by Jo") == "]0;evil deploy ok, by Jo")
        #expect(CardText.normalize("done\u{1B}[3") == "done[3")
        let unfinished = String(repeating: "\u{1B}]x\u{1B}[", count: 200_000)
        #expect(CardText.normalize(unfinished) == String(repeating: "]x[", count: 200_000))
    }

    @Test func normalizeDropsBidiControls() {
        // A folder named "\u{202E}gnipmud" would read "dumping" and reverse what follows it.
        #expect(CardText.normalize("api\u{202E} needs you") == "api needs you")
        #expect(CardText.normalize("\u{2066}a\u{2069} \u{202A}b\u{202C} \u{202B}c\u{202D}d\u{2067}\u{2068}") == "a b cd")
        // The marks that only nudge neutral characters stay, as right-to-left text needs them.
        #expect(CardText.normalize("\u{200F}שלום\u{200E}") == "\u{200F}שלום\u{200E}")
    }

    @Test func truncateLeavesShortTextAlone() {
        #expect(CardText.truncate("hello", limit: 5) == "hello")
        #expect(CardText.truncate("", limit: 5) == "")
    }

    @Test func truncateASCII() {
        #expect(CardText.truncate("hello world", limit: 6) == "hello…")
        #expect(CardText.truncate("abcdefgh", limit: 5) == "abcd…")
        #expect(CardText.truncate("abcdefgh", limit: 1) == "a")
    }

    @Test func truncateNeverSplitsEmoji() {
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family, count: 10)
        let cut = CardText.truncate(text, limit: 4)
        #expect(cut == family + family + family + "…")
        #expect(cut.count == 4)

        let flags = "🇯🇵🇺🇸🇫🇷🇩🇪"
        #expect(CardText.truncate(flags, limit: 3) == "🇯🇵🇺🇸…")

        let thumbs = "👍🏽👍🏽👍🏽"
        #expect(CardText.truncate(thumbs, limit: 2) == "👍🏽…")
    }

    @Test func truncateCJK() {
        #expect(CardText.truncate("ビルドが完了しました", limit: 4) == "ビルド…")
        #expect(CardText.truncate("构建成功", limit: 4) == "构建成功")
    }

    @Test func truncateKeepsCombiningMarks() {
        let decomposed = "e\u{0301}e\u{0301}e\u{0301}e\u{0301}"
        #expect(decomposed.count == 4)
        let cut = CardText.truncate(decomposed, limit: 3)
        #expect(cut == "e\u{0301}e\u{0301}…")
        #expect(CardText.truncate("Z\u{0351}\u{036B}\u{0343}a\u{0300}b", limit: 2) == "Z\u{0351}\u{036B}\u{0343}…")
    }

    @Test func truncateDropsTrailingSpaceBeforeTheEllipsis() {
        #expect(CardText.truncate("hello world", limit: 7) == "hello…")
    }

    /// A width close to the 14-point semibold system font's.
    private static func measure(_ text: String) -> Double {
        Double(text.count) * 7.5
    }

    @Test func fitLeavesTextThatFitsAlone() {
        let alphabet = "abcdefghijklmnopqrstuvwxyz"
        #expect(CardText.fit(alphabet, width: 500, measure: Self.measure) == alphabet)
        #expect(CardText.fit("", width: 500, measure: Self.measure) == "")
    }

    /// The owner's title: one word, three alphabets long, wider than the island's 500-point column.
    @Test func fitCutsALongWordToTheLine() {
        let word = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
        #expect(Self.measure(word) > 500)
        let fitted = CardText.fit(word, width: 500, measure: Self.measure)
        #expect(fitted == String(word.prefix(65)) + "…")
        #expect(Self.measure(fitted) <= 500)
    }

    @Test func fitCutsSpacedTextWithoutATrailingSpace() {
        let spaced = String(repeating: "A very long title that keeps going ", count: 3)
        let fitted = CardText.fit(spaced, width: 500, measure: Self.measure)
        #expect(Self.measure(fitted) <= 500)
        #expect(fitted.hasSuffix("…"))
        #expect(!fitted.dropLast().hasSuffix(" "))
        #expect(spaced.hasPrefix(fitted.dropLast()))
    }

    @Test func fitCutsVeryLongTextWithAndWithoutSpaces() {
        for text in [String(repeating: "x", count: 2000), String(repeating: "word ", count: 400)] {
            let fitted = CardText.fit(text, width: 500, measure: Self.measure)
            #expect(Self.measure(fitted) <= 500)
            #expect(Self.measure(fitted) > 480)
            #expect(fitted.hasSuffix("…"))
        }
    }

    @Test func fitNeverSplitsEmojiAndKeepsTheEllipsisWhenNothingElseFits() {
        let family = "👨‍👩‍👧‍👦"
        #expect(CardText.fit(String(repeating: family, count: 10), width: 30, measure: Self.measure)
            == family + family + family + "…")
        #expect(CardText.fit("abc", width: 10, measure: Self.measure) == "…")
    }

    /// Every character as wide as the 14-point semibold system font's average, ideographs twice that.
    private static func wide(_ text: String) -> Double {
        text.reduce(0) { width, character in
            width + (character.unicodeScalars.first?.properties.isIdeographic == true
                || ("\u{3040}"..."\u{30FF}").contains(character) ? 15 : 7.5)
        }
    }

    @Test func wrapLeavesTextThatFitsAlone() {
        let text = "Build finished"
        #expect(CardText.wrap(text, width: 500, maxLines: 2, measure: Self.measure) == [text])
        // Exactly as wide as the line: not wrapped, just as `fit` would not cut it.
        let full = String(repeating: "x", count: 66)
        #expect(Self.measure(full) == 495)
        #expect(CardText.wrap(full, width: 495, maxLines: 2, measure: Self.measure) == [full])
        #expect(CardText.fit(full, width: 495, measure: Self.measure) == full)
    }

    @Test func wrapBreaksAfterSpacesAndDropsThem() {
        let spaced = String(repeating: "A very long title that keeps going ", count: 2).trimmingCharacters(in: .whitespaces)
        let lines = CardText.wrap(spaced, width: 300, maxLines: 3, measure: Self.measure)
        #expect(lines == ["A very long title that keeps going A", "very long title that keeps going"])
        #expect(lines.allSatisfy { Self.measure($0) <= 300 })
        #expect(lines.joined(separator: " ") == spaced)
    }

    /// The last line allowed takes the rest, cut with an ellipsis like a line that does not wrap.
    @Test func wrapEndsTheLastLineInAnEllipsis() throws {
        let text = String(repeating: "word ", count: 100).trimmingCharacters(in: .whitespaces)
        for maxLines in 1...3 {
            let lines = CardText.wrap(text, width: 200, maxLines: maxLines, measure: Self.measure)
            #expect(lines.count == maxLines)
            #expect(lines.allSatisfy { Self.measure($0) <= 200 })
            #expect(lines.dropLast().allSatisfy { !$0.hasSuffix("…") && !$0.hasSuffix(" ") && !$0.hasPrefix(" ") })
            let last = try #require(lines.last)
            #expect(last.hasSuffix("…"))
            #expect(last == CardText.fit(String(text.dropFirst(lines.dropLast().map { $0.count + 1 }.reduce(0, +))),
                                         width: 200, measure: Self.measure))
        }
        #expect(CardText.wrap(text, width: 200, maxLines: 1, measure: Self.measure)
            == [CardText.fit(text, width: 200, measure: Self.measure)])
    }

    @Test func wrapCutsAWordTooLongForALine() {
        let word = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
        let lines = CardText.wrap(word, width: 500, maxLines: 2, measure: Self.measure)
        #expect(lines == [String(word.prefix(66)), String(word.dropFirst(66))])
        // A word that fits no line starts on a line of its own.
        #expect(CardText.wrap("go " + word, width: 500, maxLines: 2, measure: Self.measure)
            == ["go", String(word.prefix(65)) + "…"])
    }

    @Test func wrapBreaksBetweenIdeographsButNotBeforeClosingPunctuation() {
        let japanese = "ビルドが完了しました。テストはすべて成功しました。"
        let lines = CardText.wrap(japanese, width: 150, maxLines: 3, measure: Self.wide)
        #expect(lines.joined() == japanese)
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { Self.wide($0) <= 150 })
        #expect(lines.dropFirst().allSatisfy { !$0.hasPrefix("。") })
        // Ten characters fit a line; the eleventh would be a full stop, which never starts a line, so
        // the line breaks a character earlier and takes it along.
        #expect(lines == ["ビルドが完了しまし", "た。テストはすべて成", "功しました。"])
    }

    @Test func wrapNeverSplitsEmojiOrCombiningMarks() {
        let family = "👨‍👩‍👧‍👦"
        let lines = CardText.wrap(String(repeating: family, count: 10), width: 30, maxLines: 3, measure: Self.measure)
        #expect(lines == [String(repeating: family, count: 4), String(repeating: family, count: 4), family + family])
        #expect(CardText.wrap(String(repeating: family, count: 13), width: 30, maxLines: 3, measure: Self.measure).last
            == family + family + family + "…")
        let accents = String(repeating: "e\u{0301}", count: 10)
        #expect(CardText.wrap(accents, width: 30, maxLines: 3, measure: Self.measure)
            == [String(repeating: "e\u{0301}", count: 4), String(repeating: "e\u{0301}", count: 4),
                String(repeating: "e\u{0301}", count: 2)])
    }

    /// Right-to-left text is broken in reading order: the first line holds the start of the text.
    @Test func wrapKeepsRightToLeftTextInReadingOrder() {
        let hebrew = "שלום עולם זה כרטיס ארוך מאוד שממשיך הלאה"
        let lines = CardText.wrap(hebrew, width: 120, maxLines: 3, measure: Self.measure)
        #expect(lines.count > 1)
        #expect(hebrew.hasPrefix(lines[0]))
        #expect(lines.allSatisfy { CardText.isRightToLeft($0) })
    }

    /// A typesetter's break is used as given when it fits, and moved back to the last space when the
    /// line it makes is too wide by the renderer's own measure.
    @Test func wrapTakesTheTypesettersBreakButNeverAWiderLine() {
        let text = "one two three four five six"
        let given = CardText.wrap(text, width: 100, maxLines: 3, measure: Self.measure) { _ in 4 }
        #expect(given == ["one", "two", "three four f…"])
        let tooWide = CardText.wrap(text, width: 100, maxLines: 2, measure: Self.measure) { $0.count }
        #expect(tooWide == ["one two three", "four five six"])
        // A break of nothing still makes progress.
        #expect(CardText.wrap("ab cd", width: 10, maxLines: 2, measure: Self.measure) { _ in 0 } == ["a", "…"])
    }

    @Test func characterCountFollowsUTF16() {
        #expect(CardText.characterCount("abc", utf16Length: 2) == 2)
        // A family emoji is 11 UTF-16 code units; none of it is counted until all of it fits.
        let family = "👨‍👩‍👧‍👦"
        #expect(CardText.characterCount("a" + family + "b", utf16Length: 5) == 1)
        #expect(CardText.characterCount("a" + family + "b", utf16Length: 12) == 2)
        #expect(CardText.characterCount("abc", utf16Length: 99) == 3)
        #expect(CardText.characterCount("abc", utf16Length: 0) == 0)
    }

    @Test func voiceOverReadsTheWholeTitleThenTheDetail() {
        #expect(CardText.spoken(title: "Build finished", detail: "42 tests passed") == "Build finished, 42 tests passed")
        #expect(CardText.spoken(title: "Build finished", detail: nil) == "Build finished")
    }

    @Test func lineCaps() {
        #expect(Defaults.titleLines == 2)
        #expect(Defaults.detailLines == 3)
    }

    @Test func lineKeepsLongTextWhole() {
        let long = String(repeating: "word ", count: 200)
        #expect(CardText.line(long) == String(long.dropLast()))
    }

    @Test func lineCutsToAGivenLimit() {
        let label = CardText.line(String(repeating: "🎉", count: 25), limit: Defaults.buttonLimit)
        #expect(label?.count == 24)
        #expect(label?.last == "…")
        #expect(CardText.line(String(repeating: "x", count: 24), limit: 24)?.count == 24)
    }

    @Test func lineIsNilWhenEmpty() {
        #expect(CardText.line(nil) == nil)
        #expect(CardText.line(" \n") == nil)
        #expect(CardText.line(" a  b ") == "a b")
    }

    @Test func splitStandardInput() {
        let split = CardText.splitStandardInput("first\nsecond\r\n\nthird\n")
        #expect(split.title == "first")
        #expect(split.detail == "second third")

        let titleOnly = CardText.splitStandardInput("\n\n  only  \n")
        #expect(titleOnly.title == "  only  ")
        #expect(titleOnly.detail == nil)

        let empty = CardText.splitStandardInput(" \n\t\n")
        #expect(empty.title == nil)
        #expect(empty.detail == nil)
    }
}
