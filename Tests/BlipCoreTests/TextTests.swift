import BlipCore
import Testing

struct TextTests {
    @Test func normalizeCollapsesWhitespace() {
        #expect(CardText.normalize("  a \t\t b\n\nc\r\nd  ") == "a b c d")
        #expect(CardText.normalize("a\u{00A0}\u{00A0}b") == "a b")
        #expect(CardText.normalize("") == "")
        #expect(CardText.normalize(" \n ") == "")
    }

    @Test func normalizeDropsControlCharacters() {
        #expect(CardText.normalize("a\u{07}b\u{1B}c") == "abc")
        #expect(CardText.normalize("\u{1B}[31mred\u{1B}[0m") == "[31mred[0m")
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

    @Test func titleAndDetailLimits() {
        #expect(Defaults.titleLimit == 80)
        #expect(Defaults.detailLimit == 120)
        let title = CardText.line(String(repeating: "🎉", count: 81), limit: Defaults.titleLimit)
        #expect(title?.count == 80)
        #expect(title?.last == "…")
        #expect(CardText.line(String(repeating: "x", count: 80), limit: 80)?.count == 80)
    }

    @Test func lineIsNilWhenEmpty() {
        #expect(CardText.line(nil, limit: 80) == nil)
        #expect(CardText.line(" \n", limit: 80) == nil)
        #expect(CardText.line(" a  b ", limit: 80) == "a b")
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
