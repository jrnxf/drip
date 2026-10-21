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

    /// No released drip had a `notch` key: it is unknown, as any other, and DRIP_NOTCH is not read.
    @Test func notchIsNoSetting() throws {
        let file = try ConfigLoader.parse("""
            position = "notch"
            notch    = "ears"
            motion   = "subtle"
            """, path: path)
        #expect(file.warnings == ["\(path):2: unknown key 'notch'"])
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
            ["ok", "t", "--style", "wash", "--position", "notch"])
        else { Issue.record("did not parse"); return }
        let flags = command.options.flags
        #expect(flags.style == .wash)
        #expect(flags.position == .notch)
    }

    /// The motion is a viewing preference, set in the config or DRIP_MOTION; only the snapshot
    /// tests' `__render` takes it per card.
    @Test func motionIsASettingNotAFlag() throws {
        guard case let .exit(status, message) = CommandLineParser.parse(["ok", "t", "--motion", "none"]) else {
            Issue.record("--motion parsed"); return
        }
        #expect(status == ExitStatus.usage)
        #expect(message == "drip: unknown option '--motion'. Did you mean '--position'?\nSee 'drip --help'.")
        guard case let .invocation(.render(command)) = CommandLineParser.parse(
            ["__render", "--out", "x.png", "ok", "t", "--motion", "none"])
        else { Issue.record("__render --motion did not parse"); return }
        #expect(command.flags.motion == Motion.none)
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

    @Test func demoPlaysChainThenPushUnlessOneIsNamed() throws {
        let both = { (arguments: [String]) -> [StackSettings.Mode]? in
            guard case let .invocation(.demo(command)) = CommandLineParser.parse(arguments) else { return nil }
            return command.stacks
        }
        #expect(both(["demo"]) == [.chain, .push])
        #expect(both(["demo", "push"]) == [.push])
        #expect(both(["demo", "--seconds", "3", "chain"]) == [.chain])
        guard case .exit(ExitStatus.usage, _) = CommandLineParser.parse(["demo", "off"]) else {
            Issue.record("demo off parsed"); return
        }
    }

    @Test func demoHoldsTheReportBackWhateverDripStackSays() {
        let stack = DemoCommand.stack(.push, environment: ["DRIP_STACK": "off"], config: Config())
        #expect(stack.mode == .push)
        #expect(stack.max == 3)
        #expect(stack.pauses == [0, 0, 0, 3])
    }

    @Test func demoDropsSeveralNotchCards() throws {
        let cards = try DemoCommand.cards(
            CardResolver(), flags: CardFlags(position: .bottom, id: "shared"))
        #expect(cards.map(\.kind) == ["ok", "ask", "fail", "info"])
        #expect(Set(cards.map(\.title)).count == cards.count)
        for card in cards {
            #expect(card.position == .notch)
            #expect(card.id == nil)
            #expect(card.detail != nil)
        }
    }

    @Test func demoEndsWithACardWithAButton() throws {
        let cards = try DemoCommand.cards(CardResolver(), flags: CardFlags())
        #expect(cards.dropLast().allSatisfy { $0.action == nil })
        #expect(cards.last?.action?.label == "Open")
        #expect(cards.last?.action?.open == "https://github.com/jrnxf/drip")
        #expect(cards.last?.asksQuestion == false)
    }

    @Test func demoButtonFlagsApplyToEveryCard() throws {
        let cards = try DemoCommand.cards(CardResolver(), flags: CardFlags(open: "https://example.com"))
        #expect(cards.allSatisfy { $0.action?.open == "https://example.com" })
    }

    @Test func demoDetailReplacesEverySample() throws {
        let cards = try DemoCommand.cards(CardResolver(), flags: CardFlags(detail: "mine"))
        #expect(cards.allSatisfy { $0.detail == "mine" })
    }

    @Test func demoWarnsAboutFlagsThatDoNothingAtTheNotch() {
        let flags = CardFlags(position: .top, style: .glass)
        #expect(DemoCommand.warnings(flags: flags) == [
            "drip demo shows only notch cards, so --position does nothing",
            "drip demo shows only notch cards, so --style does nothing",
        ])
        #expect(DemoCommand.warnings(flags: CardFlags()).isEmpty)
    }

    @Test func renderTakesATime() throws {
        guard case let .invocation(.render(command)) = CommandLineParser.parse(
            ["__render", "--out", "x.png", "ok", "t", "--position", "notch", "--at", "0.3"])
        else { Issue.record("did not parse"); return }
        #expect(command.at == 0.3)
    }
}
