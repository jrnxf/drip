import DripCore
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

    /// `ask` is no kind: `--stay` keeps a card on screen, and `--yes` and `--no` ask. The error says
    /// so, with or without a title, unless a custom preset takes the name.
    @Test func askIsNoKind() throws {
        for title in ["my-app needs you", nil] {
            let error = #expect(throws: UsageError.self) {
                try resolver.resolve(kind: "ask", title: title, flags: CardFlags(), standardInput: { "from stdin" })
            }
            #expect(error?.message.hasPrefix("'ask' is not a kind") == true)
            #expect(error?.message.contains("--stay") == true)
            #expect(error?.message.contains("--yes") == true)
        }
        let custom = CardResolver(config: Config(presets: ["ask": PresetOverride(stay: true)]))
        #expect(try custom.resolve(kind: "ask", title: "t", flags: CardFlags()).waits)
    }

    @Test func unknownPresetWithATitleIsAUsageError() {
        let error = #expect(throws: UsageError.self) {
            try resolver.resolve(kind: "okay", title: "hi", flags: CardFlags())
        }
        #expect(error?.message.hasPrefix("unknown preset 'okay'") == true)
    }

    /// The likeliest first mistake, a title of several words unquoted: the error says how to quote it.
    @Test func anUnquotedTitleSaysHowToQuoteIt() {
        func message(_ kind: String, _ title: String, _ rest: [String] = []) -> String? {
            #expect(throws: UsageError.self) { try resolver.resolve(kind: kind, title: title, rest: rest, flags: CardFlags()) }?.message
        }
        #expect(message("build", "finished") == """
            unknown preset 'build' (known: fail, info, ok, warn)
            To show "build finished" as the title, quote it: drip "build finished"
            """)
        #expect(message("build", "is", ["done"])?.hasSuffix(#"quote it: drip "build is done""#) == true)
        #expect(message("ok", "build", ["is", "done"]) == """
            unexpected argument 'is'
            To show "build is done" as the title, quote it: drip ok "build is done"
            """)
        // Quoted so that a shell reads it back as written.
        #expect(message("deploy", "$HOME", ["isn't", "set"])?.hasSuffix(#"quote it: drip 'deploy $HOME isn'\''t set'"#) == true)
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
        #expect(card.size == .regular)
    }

    @Test func flagsOverrideThePreset() throws {
        let flags = CardFlags(
            detail: "d", seconds: 8, sound: .named("Hero"), icon: .symbol("paperplane.fill"),
            color: .rgb(red: 1, green: 2, blue: 3), size: .large)
        let card = try resolver.resolve(kind: "fail", title: "hi", flags: flags)
        #expect(card.detail == "d")
        #expect(card.seconds == 8)
        #expect(card.sound == .named("Hero"))
        #expect(card.icon == .symbol("paperplane.fill"))
        #expect(card.fallbackIcon == .symbol("xmark.circle.fill"))
        #expect(card.color == .rgb(red: 1, green: 2, blue: 3))
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

    @Test func titleAndDetailAreNormalizedAndKeptWhole() throws {
        let card = try resolver.resolve(
            kind: "ok", title: "  build\t\tfinished\n", flags: CardFlags(detail: String(repeating: "d", count: 300)))
        #expect(card.title == "build finished")
        #expect(card.detail == String(repeating: "d", count: 300))

        let long = try resolver.resolve(kind: "ok", title: String(repeating: "t", count: 300), flags: CardFlags())
        #expect(long.title == String(repeating: "t", count: 300))
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
