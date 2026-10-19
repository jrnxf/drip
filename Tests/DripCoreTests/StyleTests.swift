import DripCore
import Testing

struct StyleSettingsTests {
    private let path = "/home/me/.config/drip/config.toml"

    @Test func configReadsStyleMotionAndPresetStyles() throws {
        let file = try ConfigLoader.parse("""
            style    = "glass"
            position = "notch"
            motion   = "subtle"

            [preset.fail]
            style = "wash"
            """, path: path)
        #expect(file.warnings == [])
        #expect(file.config == Config(
            position: .notch, style: .glass, motion: .subtle, presets: ["fail": PresetOverride(style: .wash)]))
        #expect(file.config.allPresets.first { $0.name == "fail" }?.style == .wash)
        #expect(file.config.allPresets.first { $0.name == "ok" }?.style == nil)
    }

    /// droplet is the only notch motion now: an old `notch` key is a warning, whatever its value, and
    /// DRIP_NOTCH is not read at all.
    @Test func theRemovedNotchSettingIsIgnored() throws {
        let file = try ConfigLoader.parse("""
            position = "notch"
            notch    = "ears"
            motion   = "subtle"
            """, path: path)
        #expect(file.warnings == ["\(path):2: 'notch' is no longer used; droplet is the only notch motion"])
        #expect(file.config == Config(position: .notch, motion: .subtle))
        #expect(try ConfigLoader.parse("notch = 3", path: path).config == Config())
        #expect(try EnvironmentSettings(environment: ["DRIP_NOTCH": "drip"]) == EnvironmentSettings())
    }

    @Test func environmentReadsStyleAndMotion() throws {
        let settings = try EnvironmentSettings(environment: [
            "DRIP_STYLE": "terminal", "DRIP_MOTION": "none", "DRIP_POSITION": "notch",
        ])
        #expect(settings == EnvironmentSettings(position: .notch, style: .terminal, motion: Motion.none))
        let error = #expect(throws: UsageError.self) { try EnvironmentSettings(environment: ["DRIP_STYLE": "neon"]) }
        #expect(error?.message == "DRIP_STYLE must be hud, glass, wash or terminal, not 'neon'")
    }

    @Test func styleComesFromFlagsThenEnvironmentThenPresetThenConfigThenTheDisplay() throws {
        let config = Config(style: .terminal, presets: ["fail": PresetOverride(style: .wash)])
        func style(flags: CardFlags = CardFlags(), environment: EnvironmentSettings = EnvironmentSettings(),
                   config: Config = Config(), kind: String = "ok") throws -> CardStyle {
            try CardResolver(config: config, environment: environment, automaticStyle: .glass)
                .resolve(kind: kind, title: "t", flags: flags).style
        }
        #expect(try style() == .glass)
        #expect(try style(config: config) == .terminal)
        #expect(try style(config: config, kind: "fail") == .wash)
        #expect(try style(environment: EnvironmentSettings(style: .hud), config: config, kind: "fail") == .hud)
        #expect(try style(flags: CardFlags(style: .glass), environment: EnvironmentSettings(style: .hud)) == .glass)
        #expect(try CardResolver().resolve(kind: "ok", title: "t", flags: CardFlags()).style == Defaults.style)
    }

    @Test func motionComesFromFlagsThenEnvironmentThenConfig() throws {
        let resolver = CardResolver(config: Config(motion: .subtle))
        let card = try resolver.resolve(kind: "ok", title: "t", flags: CardFlags())
        #expect(card.motion == .subtle)
        let environment = CardResolver(config: Config(motion: .subtle), environment: EnvironmentSettings(motion: .full))
        #expect(try environment.resolve(kind: "ok", title: "t", flags: CardFlags()).motion == .full)
        let flagged = try resolver.resolve(kind: "ok", title: "t", flags: CardFlags(motion: Motion.none))
        #expect(flagged.motion == Motion.none)
        let defaults = try CardResolver().resolve(kind: "ok", title: "t", flags: CardFlags())
        #expect(defaults.motion == .full)
    }

    @Test func dripRunCardsTakeTheirPresetStyle() throws {
        let resolver = CardResolver(config: Config(presets: ["fail": PresetOverride(style: .wash)]))
        let failed = try resolver.resolveRun(command: ["make"], status: 2, seconds: 1, flags: CardFlags())
        #expect(failed.style == .wash)
        let passed = try resolver.resolveRun(command: ["make"], status: 0, seconds: 1, flags: CardFlags())
        #expect(passed.style == Defaults.style)
    }

    @Test func reduceMotionCapsFullAtSubtle() {
        #expect(Motion.full.capped(reduceMotion: true) == .subtle)
        #expect(Motion.full.capped(reduceMotion: false) == .full)
        #expect(Motion.subtle.capped(reduceMotion: true) == .subtle)
        #expect(Motion.none.capped(reduceMotion: true) == Motion.none)
    }
}

struct StyleCommandTests {
    @Test func flagsParse() throws {
        guard case let .invocation(.show(command)) = CommandLineParser.parse(
            ["ok", "t", "--style", "wash", "--motion", "none", "--position", "notch"])
        else { Issue.record("did not parse"); return }
        let flags = command.options.flags
        #expect(flags.style == .wash)
        #expect(flags.motion == Motion.none)
        #expect(flags.position == .notch)
    }

    @Test func theRemovedNotchFlagIsAUsageError() {
        guard case let .exit(status, message) = CommandLineParser.parse(["ok", "t", "--notch", "droplet"]) else {
            Issue.record("parsed"); return
        }
        #expect(status == ExitStatus.usage)
        #expect(message.contains("--notch"))
    }

    @Test func invalidStyleIsAUsageError() {
        guard case let .exit(status, message) = CommandLineParser.parse(["ok", "t", "--style", "neon"]) else {
            Issue.record("parsed"); return
        }
        #expect(status == ExitStatus.usage)
        #expect(!message.isEmpty)
    }

    @Test func demoIsASubcommand() throws {
        guard case let .invocation(.demo(command)) = CommandLineParser.parse(["demo", "--style", "glass"]) else {
            Issue.record("demo did not parse"); return
        }
        #expect(command.options.flags.style == .glass)
        guard case .exit(0, _) = CommandLineParser.parse(["demo", "--help"]) else {
            Issue.record("demo --help did not print help"); return
        }
    }

    @Test func demoDropsSeveralNotchCards() throws {
        let cards = try DemoCommand.cards(
            CardResolver(), flags: CardFlags(position: .bottom, id: "shared"))
        #expect(cards.map(\.kind) == ["ok", "warn", "fail"])
        #expect(Set(cards.map(\.title)).count == cards.count)
        for card in cards {
            #expect(card.position == .notch)
            #expect(card.id == nil)
            #expect(card.detail != nil)
        }
    }

    @Test func demoDetailReplacesEverySample() throws {
        let cards = try DemoCommand.cards(CardResolver(), flags: CardFlags(detail: "mine"))
        #expect(cards.allSatisfy { $0.detail == "mine" })
    }

    @Test func demoWarnsAboutFlagsThatDoNothingAtTheNotch() {
        let flags = CardFlags(position: .top, style: .glass)
        #expect(DemoCommand.warnings(flags: flags, hasNotch: true) == [
            "drip demo shows only notch cards, so --position does nothing",
            "drip demo shows only notch cards, so --style does nothing",
        ])
        #expect(DemoCommand.warnings(flags: CardFlags(), hasNotch: true).isEmpty)
    }

    @Test func demoWithoutANotchWarnsWhereCardsShowAndKeepsStyle() {
        #expect(DemoCommand.warnings(flags: CardFlags(style: .glass), hasNotch: false) == [
            "this screen has no notch, so the cards show at the top",
        ])
        #expect(DemoCommand.warnings(flags: CardFlags(position: .top), hasNotch: false) == [
            "drip demo shows only notch cards, so --position does nothing",
            "this screen has no notch, so the cards show at the top",
        ])
    }

    @Test func renderTakesATime() throws {
        guard case let .invocation(.render(command)) = CommandLineParser.parse(
            ["__render", "--out", "x.png", "ok", "t", "--position", "notch", "--at", "0.3"])
        else { Issue.record("did not parse"); return }
        #expect(command.at == 0.3)
    }
}
