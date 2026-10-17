import BlipCore
import Testing

struct ResolveTests {
    private let resolver = CardResolver()

    @Test func knownPresetIsTheKind() throws {
        let card = try resolver.resolve(kind: "ok", title: "hi", flags: CardFlags(detail: "there"))
        #expect(card == Card(preset: .ok, title: "hi", detail: "there"))
    }

    @Test func eachBuiltInPreset() throws {
        for preset in Preset.builtIn {
            #expect(try resolver.resolve(kind: preset.name, title: "t", flags: CardFlags()) == Card(preset: preset, title: "t"))
        }
    }

    @Test func firstPositionalThatIsNotAPresetIsTheTitle() throws {
        let card = try resolver.resolve(kind: "build finished", title: nil, flags: CardFlags())
        #expect(card == Card(preset: .info, title: "build finished"))
    }

    @Test func unknownPresetWithATitleIsAUsageError() {
        let error = #expect(throws: UsageError.self) {
            try resolver.resolve(kind: "okay", title: "hi", flags: CardFlags())
        }
        #expect(error?.message.hasPrefix("unknown preset 'okay'") == true)
    }

    @Test func missingTitleIsAUsageError() {
        #expect(throws: UsageError.self) { try resolver.resolve(kind: nil, title: nil, flags: CardFlags()) }
        #expect(throws: UsageError.self) { try resolver.resolve(kind: "ok", title: nil, flags: CardFlags()) }
        #expect(throws: UsageError.self) { try resolver.resolve(kind: "ok", title: "", flags: CardFlags()) }
        #expect(throws: UsageError.self) { try resolver.resolve(kind: "ok", title: " \n\t ", flags: CardFlags()) }
    }

    @Test func defaults() throws {
        let card = try resolver.resolve(kind: "warn", title: "hi", flags: CardFlags())
        #expect(card.detail == nil)
        #expect(card.seconds == 4.5)
        #expect(card.sound == .named("Purr"))
        #expect(card.icon == .symbol("exclamationmark.circle.fill"))
        #expect(card.color == .system(.orange))
        #expect(card.position == .notch)
        #expect(card.size == .regular)
    }

    @Test func flagsOverrideThePreset() throws {
        let flags = CardFlags(
            detail: "d", seconds: 8, sound: .named("Hero"), icon: .symbol("paperplane.fill"),
            color: .rgb(red: 1, green: 2, blue: 3), position: .top, size: .large)
        let card = try resolver.resolve(kind: "fail", title: "hi", flags: flags)
        #expect(card.detail == "d")
        #expect(card.seconds == 8)
        #expect(card.sound == .named("Hero"))
        #expect(card.icon == .symbol("paperplane.fill"))
        #expect(card.fallbackIcon == .symbol("xmark.circle.fill"))
        #expect(card.color == .rgb(red: 1, green: 2, blue: 3))
        #expect(card.position == .top)
        #expect(card.size == .large)
    }

    @Test func noneMutesAndHidesTheIcon() throws {
        let card = try resolver.resolve(kind: "ok", title: "hi", flags: CardFlags(sound: Sound.none, icon: Icon.none))
        #expect(card.sound == Sound.none)
        #expect(card.icon == Icon.none)
    }

    @Test func standardInputSuppliesTitleAndDetail() throws {
        let card = try resolver.resolve(kind: "ok", title: nil, flags: CardFlags()) {
            "\n  feat: show hidden files\nColby Thomas\n\nsecond paragraph\n"
        }
        #expect(card.kind == "ok")
        #expect(card.title == "feat: show hidden files")
        #expect(card.detail == "Colby Thomas second paragraph")
    }

    @Test func standardInputWithoutKind() throws {
        let card = try resolver.resolve(kind: nil, title: nil, flags: CardFlags()) { "just a title" }
        #expect(card == Card(preset: .info, title: "just a title"))
    }

    @Test func detailFlagWinsOverStandardInput() throws {
        let card = try resolver.resolve(kind: "ok", title: nil, flags: CardFlags(detail: "flag")) { "title\nstdin" }
        #expect(card.title == "title")
        #expect(card.detail == "flag")
    }

    @Test func standardInputIsNotReadWhenATitleIsGiven() throws {
        let card = try resolver.resolve(kind: "ok", title: "hi", flags: CardFlags()) {
            Issue.record("stdin was read")
            return "other"
        }
        #expect(card.title == "hi")
        _ = try resolver.resolve(kind: "a title", title: nil, flags: CardFlags()) {
            Issue.record("stdin was read")
            return nil
        }
    }

    @Test func emptyStandardInputIsAMissingTitle() {
        #expect(throws: UsageError.self) { try resolver.resolve(kind: "ok", title: nil, flags: CardFlags()) { "\n \n" } }
        #expect(throws: UsageError.self) { try resolver.resolve(kind: "ok", title: nil, flags: CardFlags()) { nil } }
    }

    @Test func titleAndDetailAreNormalizedAndTruncated() throws {
        let card = try resolver.resolve(
            kind: "ok", title: "  build\t\tfinished\n", flags: CardFlags(detail: String(repeating: "d", count: 300)))
        #expect(card.title == "build finished")
        #expect(card.detail?.count == 120)
        #expect(card.detail?.last == "…")

        let long = try resolver.resolve(kind: "ok", title: String(repeating: "t", count: 300), flags: CardFlags())
        #expect(long.title.count == 80)
        #expect(long.title == String(repeating: "t", count: 79) + "…")
    }

    @Test func blankDetailIsDropped() throws {
        #expect(try resolver.resolve(kind: "ok", title: "hi", flags: CardFlags(detail: "  ")).detail == nil)
    }

    @Test func runCardForSuccess() throws {
        let card = try resolver.resolveRun(command: ["make", "test"], status: 0, seconds: 192.4, flags: CardFlags())
        #expect(card.kind == "ok")
        #expect(card.title == "make test finished")
        #expect(card.detail == "3m 12s")
        #expect(card.sound == .named("Glass"))
    }

    @Test func runCardForFailure() throws {
        let card = try resolver.resolveRun(
            command: ["false"], status: 1, seconds: 0.01, flags: CardFlags(seconds: 2, sound: Sound.none))
        #expect(card.kind == "fail")
        #expect(card.title == "false failed (exit 1)")
        #expect(card.detail == "0.0s")
        #expect(card.seconds == 2)
        #expect(card.sound == Sound.none)
    }

    @Test func runCardDetailFlagWins() throws {
        let card = try resolver.resolveRun(command: ["true"], status: 0, seconds: 1, flags: CardFlags(detail: "ci"))
        #expect(card.detail == "ci")
    }
}
