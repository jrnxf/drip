import BlipCore
import XCTest

final class ResolveTests: XCTestCase {
    private let resolver = CardResolver()

    func testKnownPresetIsTheKind() throws {
        let card = try resolver.resolve(kind: "ok", title: "hi", flags: CardFlags(detail: "there"))
        XCTAssertEqual(card, Card(preset: .ok, title: "hi", detail: "there"))
    }

    func testEachBuiltInPreset() throws {
        for preset in Preset.builtIn {
            XCTAssertEqual(try resolver.resolve(kind: preset.name, title: "t", flags: CardFlags()),
                           Card(preset: preset, title: "t"))
        }
    }

    func testFirstPositionalThatIsNotAPresetIsTheTitle() throws {
        let card = try resolver.resolve(kind: "build finished", title: nil, flags: CardFlags())
        XCTAssertEqual(card, Card(preset: .info, title: "build finished"))
    }

    func testUnknownPresetWithATitleIsAUsageError() {
        XCTAssertThrowsError(try resolver.resolve(kind: "okay", title: "hi", flags: CardFlags())) { error in
            XCTAssertEqual((error as? UsageError)?.message.hasPrefix("unknown preset 'okay'"), true)
        }
    }

    func testMissingTitleIsAUsageError() {
        XCTAssertThrowsError(try resolver.resolve(kind: nil, title: nil, flags: CardFlags()))
        XCTAssertThrowsError(try resolver.resolve(kind: "ok", title: nil, flags: CardFlags()))
        XCTAssertThrowsError(try resolver.resolve(kind: "ok", title: "", flags: CardFlags()))
        XCTAssertThrowsError(try resolver.resolve(kind: "ok", title: " \n\t ", flags: CardFlags()))
    }

    func testDefaults() throws {
        let card = try resolver.resolve(kind: "warn", title: "hi", flags: CardFlags())
        XCTAssertNil(card.detail)
        XCTAssertEqual(card.seconds, 4.5)
        XCTAssertEqual(card.sound, .named("Purr"))
        XCTAssertEqual(card.icon, .symbol("exclamationmark.circle.fill"))
        XCTAssertEqual(card.color, .system(.orange))
        XCTAssertEqual(card.position, .bottom)
        XCTAssertEqual(card.size, .regular)
    }

    func testFlagsOverrideThePreset() throws {
        let flags = CardFlags(
            detail: "d", seconds: 8, sound: .named("Hero"), icon: .symbol("paperplane.fill"),
            color: .rgb(red: 1, green: 2, blue: 3), position: .top, size: .large)
        let card = try resolver.resolve(kind: "fail", title: "hi", flags: flags)
        XCTAssertEqual(card.detail, "d")
        XCTAssertEqual(card.seconds, 8)
        XCTAssertEqual(card.sound, .named("Hero"))
        XCTAssertEqual(card.icon, .symbol("paperplane.fill"))
        XCTAssertEqual(card.fallbackIcon, .symbol("xmark.circle.fill"))
        XCTAssertEqual(card.color, .rgb(red: 1, green: 2, blue: 3))
        XCTAssertEqual(card.position, .top)
        XCTAssertEqual(card.size, .large)
    }

    func testNoneMutesAndHidesTheIcon() throws {
        let card = try resolver.resolve(kind: "ok", title: "hi", flags: CardFlags(sound: Sound.none, icon: Icon.none))
        XCTAssertEqual(card.sound, Sound.none)
        XCTAssertEqual(card.icon, Icon.none)
    }

    func testStandardInputSuppliesTitleAndDetail() throws {
        let card = try resolver.resolve(kind: "ok", title: nil, flags: CardFlags()) {
            "\n  feat: show hidden files\nColby Thomas\n\nsecond paragraph\n"
        }
        XCTAssertEqual(card.kind, "ok")
        XCTAssertEqual(card.title, "feat: show hidden files")
        XCTAssertEqual(card.detail, "Colby Thomas second paragraph")
    }

    func testStandardInputWithoutKind() throws {
        let card = try resolver.resolve(kind: nil, title: nil, flags: CardFlags()) { "just a title" }
        XCTAssertEqual(card, Card(preset: .info, title: "just a title"))
    }

    func testDetailFlagWinsOverStandardInput() throws {
        let card = try resolver.resolve(kind: "ok", title: nil, flags: CardFlags(detail: "flag")) { "title\nstdin" }
        XCTAssertEqual(card.title, "title")
        XCTAssertEqual(card.detail, "flag")
    }

    func testStandardInputIsNotReadWhenATitleIsGiven() throws {
        let card = try resolver.resolve(kind: "ok", title: "hi", flags: CardFlags()) {
            XCTFail("stdin was read")
            return "other"
        }
        XCTAssertEqual(card.title, "hi")
        _ = try resolver.resolve(kind: "a title", title: nil, flags: CardFlags()) {
            XCTFail("stdin was read")
            return nil
        }
    }

    func testEmptyStandardInputIsAMissingTitle() {
        XCTAssertThrowsError(try resolver.resolve(kind: "ok", title: nil, flags: CardFlags()) { "\n \n" })
        XCTAssertThrowsError(try resolver.resolve(kind: "ok", title: nil, flags: CardFlags()) { nil })
    }

    func testTitleAndDetailAreNormalizedAndTruncated() throws {
        let card = try resolver.resolve(
            kind: "ok", title: "  build\t\tfinished\n", flags: CardFlags(detail: String(repeating: "d", count: 300)))
        XCTAssertEqual(card.title, "build finished")
        XCTAssertEqual(card.detail?.count, 120)
        XCTAssertEqual(card.detail?.last, "…")

        let long = try resolver.resolve(kind: "ok", title: String(repeating: "t", count: 300), flags: CardFlags())
        XCTAssertEqual(long.title.count, 80)
        XCTAssertEqual(long.title, String(repeating: "t", count: 79) + "…")
    }

    func testBlankDetailIsDropped() throws {
        XCTAssertNil(try resolver.resolve(kind: "ok", title: "hi", flags: CardFlags(detail: "  ")).detail)
    }

    func testRunCardForSuccess() throws {
        let card = try resolver.resolveRun(command: ["make", "test"], status: 0, seconds: 192.4, flags: CardFlags())
        XCTAssertEqual(card.kind, "ok")
        XCTAssertEqual(card.title, "make test finished")
        XCTAssertEqual(card.detail, "3m 12s")
        XCTAssertEqual(card.sound, .named("Glass"))
    }

    func testRunCardForFailure() throws {
        let card = try resolver.resolveRun(
            command: ["false"], status: 1, seconds: 0.01, flags: CardFlags(seconds: 2, sound: Sound.none))
        XCTAssertEqual(card.kind, "fail")
        XCTAssertEqual(card.title, "false failed (exit 1)")
        XCTAssertEqual(card.detail, "0.0s")
        XCTAssertEqual(card.seconds, 2)
        XCTAssertEqual(card.sound, Sound.none)
    }

    func testRunCardDetailFlagWins() throws {
        let card = try resolver.resolveRun(command: ["true"], status: 0, seconds: 1, flags: CardFlags(detail: "ci"))
        XCTAssertEqual(card.detail, "ci")
    }
}
