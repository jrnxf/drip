import BlipCore
import XCTest

final class TextTests: XCTestCase {
    func testNormalizeCollapsesWhitespace() {
        XCTAssertEqual(CardText.normalize("  a \t\t b\n\nc\r\nd  "), "a b c d")
        XCTAssertEqual(CardText.normalize("a\u{00A0}\u{00A0}b"), "a b")
        XCTAssertEqual(CardText.normalize(""), "")
        XCTAssertEqual(CardText.normalize(" \n "), "")
    }

    func testNormalizeDropsControlCharacters() {
        XCTAssertEqual(CardText.normalize("a\u{07}b\u{1B}c"), "abc")
        XCTAssertEqual(CardText.normalize("\u{1B}[31mred\u{1B}[0m"), "[31mred[0m")
    }

    func testTruncateLeavesShortTextAlone() {
        XCTAssertEqual(CardText.truncate("hello", limit: 5), "hello")
        XCTAssertEqual(CardText.truncate("", limit: 5), "")
    }

    func testTruncateASCII() {
        XCTAssertEqual(CardText.truncate("hello world", limit: 6), "hello…")
        XCTAssertEqual(CardText.truncate("abcdefgh", limit: 5), "abcd…")
        XCTAssertEqual(CardText.truncate("abcdefgh", limit: 1), "a")
    }

    func testTruncateNeverSplitsEmoji() {
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family, count: 10)
        let cut = CardText.truncate(text, limit: 4)
        XCTAssertEqual(cut, family + family + family + "…")
        XCTAssertEqual(cut.count, 4)

        let flags = "🇯🇵🇺🇸🇫🇷🇩🇪"
        XCTAssertEqual(CardText.truncate(flags, limit: 3), "🇯🇵🇺🇸…")

        let thumbs = "👍🏽👍🏽👍🏽"
        XCTAssertEqual(CardText.truncate(thumbs, limit: 2), "👍🏽…")
    }

    func testTruncateCJK() {
        XCTAssertEqual(CardText.truncate("ビルドが完了しました", limit: 4), "ビルド…")
        XCTAssertEqual(CardText.truncate("构建成功", limit: 4), "构建成功")
    }

    func testTruncateKeepsCombiningMarks() {
        let decomposed = "e\u{0301}e\u{0301}e\u{0301}e\u{0301}"
        XCTAssertEqual(decomposed.count, 4)
        let cut = CardText.truncate(decomposed, limit: 3)
        XCTAssertEqual(cut, "e\u{0301}e\u{0301}…")
        XCTAssertEqual(CardText.truncate("Z\u{0351}\u{036B}\u{0343}a\u{0300}b", limit: 2), "Z\u{0351}\u{036B}\u{0343}…")
    }

    func testTruncateDropsTrailingSpaceBeforeTheEllipsis() {
        XCTAssertEqual(CardText.truncate("hello world", limit: 7), "hello…")
    }

    func testTitleAndDetailLimits() {
        XCTAssertEqual(Defaults.titleLimit, 80)
        XCTAssertEqual(Defaults.detailLimit, 120)
        let title = CardText.line(String(repeating: "🎉", count: 81), limit: Defaults.titleLimit)
        XCTAssertEqual(title?.count, 80)
        XCTAssertEqual(title?.last, "…")
        XCTAssertEqual(CardText.line(String(repeating: "x", count: 80), limit: 80)?.count, 80)
    }

    func testLineIsNilWhenEmpty() {
        XCTAssertNil(CardText.line(nil, limit: 80))
        XCTAssertNil(CardText.line(" \n", limit: 80))
        XCTAssertEqual(CardText.line(" a  b ", limit: 80), "a b")
    }

    func testSplitStandardInput() {
        let split = CardText.splitStandardInput("first\nsecond\r\n\nthird\n")
        XCTAssertEqual(split.title, "first")
        XCTAssertEqual(split.detail, "second third")

        let titleOnly = CardText.splitStandardInput("\n\n  only  \n")
        XCTAssertEqual(titleOnly.title, "  only  ")
        XCTAssertNil(titleOnly.detail)

        let empty = CardText.splitStandardInput(" \n\t\n")
        XCTAssertNil(empty.title)
        XCTAssertNil(empty.detail)
    }
}
