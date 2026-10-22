import DripCore
import Testing

/// `position` and `style` are retired: every card shows at the notch, drawn one way. Old configs,
/// scripts and environments still set them, so drip takes any value, warns once for each and goes on;
/// `position` set to `notch` asks for what drip does anyway, so it is no warning.
struct RetiredSettingTests {
    private let path = "/home/me/.config/drip/config.toml"
    private let doesNothing = "does nothing: every card shows at the notch"

    @Test func theConfigWarnsAboutEachRetiredKeyAndReadsTheRest() throws {
        let file = try ConfigLoader.parse("""
            style    = "glass"
            position = "bottom"
            motion   = "subtle"

            [preset.fail]
            style = "wash"
            color = "red"
            """, path: path)
        #expect(file.warnings == [
            "\(path):1: 'style' \(doesNothing)",
            "\(path):2: 'position' \(doesNothing)",
            "\(path):6: 'preset.fail.style' \(doesNothing)",
        ])
        #expect(file.config == Config(motion: .subtle, presets: ["fail": PresetOverride(color: .system(.red))]))
    }

    @Test func theConfigTakesAnyValueForARetiredKey() throws {
        let file = try ConfigLoader.parse("""
            style    = "neon"
            position = 3
            """, path: path)
        #expect(file.warnings == ["\(path):1: 'style' \(doesNothing)", "\(path):2: 'position' \(doesNothing)"])
        #expect(file.config == Config())
    }

    @Test func positionNotchIsNoWarning() throws {
        let file = try ConfigLoader.parse("position = \"notch\"", path: path)
        #expect(file.warnings == [])
        #expect(file.config == Config())
        #expect(try EnvironmentSettings(environment: ["DRIP_POSITION": "notch"]).warnings == [])
        #expect(try options(["ok", "t", "--position", "notch"]).warnings == [])
    }

    /// No released drip had a `notch` key: it is unknown, as any other, and DRIP_NOTCH is not read.
    @Test func notchIsNoSetting() throws {
        let file = try ConfigLoader.parse("""
            position = "notch"
            notch    = "ears"
            motion   = "subtle"
            """, path: path)
        #expect(file.warnings == ["\(path):2: unknown key 'notch'"])
        #expect(file.config == Config(motion: .subtle))
        #expect(try ConfigLoader.parse("notch = 3", path: path).config == Config())
        #expect(try EnvironmentSettings(environment: ["DRIP_NOTCH": "drip"]) == EnvironmentSettings())
    }

    @Test func theEnvironmentWarnsAboutEachRetiredVariableAndReadsTheRest() throws {
        let settings = try EnvironmentSettings(environment: [
            "DRIP_STYLE": "neon", "DRIP_POSITION": "top", "DRIP_MOTION": "none",
        ])
        var expected = EnvironmentSettings(motion: Motion.none)
        expected.warnings = ["DRIP_POSITION \(doesNothing)", "DRIP_STYLE \(doesNothing)"]
        #expect(settings == expected)
        #expect(try EnvironmentSettings(environment: ["DRIP_STYLE": "", "DRIP_POSITION": ""]).warnings == [])
    }

    @Test func theFlagsAreTakenWithAnyValueAndWarnedAbout() throws {
        let given = try options(["ok", "t", "--style", "terminal", "--position", "bottom"])
        #expect(given.flags == CardFlags())
        #expect(given.warnings == ["--position \(doesNothing)", "--style \(doesNothing)"])
        #expect(try options(["ok", "t", "--style", "neon"]).warnings == ["--style \(doesNothing)"])
        #expect(try options(["ok", "t"]).warnings == [])
    }

    @Test func everyCommandThatShowsACardTakesThem() throws {
        guard case let .invocation(.run(run)) = CommandLineParser.parse(["run", "--position", "top", "--style", "wash", "ls"])
        else { Issue.record("run did not parse"); return }
        #expect(run.command == ["ls"])
        #expect(run.options.warnings == ["--position \(doesNothing)", "--style \(doesNothing)"])
        guard case let .invocation(.hook(hook)) = CommandLineParser.parse(["hook", "claude", "--style", "hud"])
        else { Issue.record("hook did not parse"); return }
        #expect(hook.options.warnings == ["--style \(doesNothing)"])
        guard case let .invocation(.demo(demo)) = CommandLineParser.parse(["demo", "--style", "glass"])
        else { Issue.record("demo did not parse"); return }
        #expect(demo.options.warnings == ["--style \(doesNothing)"])
    }

    private func options(_ arguments: [String]) throws -> CardOptions {
        guard case let .invocation(.show(command)) = CommandLineParser.parse(arguments) else {
            throw UsageError("\(arguments) did not parse")
        }
        return command.options
    }
}

struct MotionSettingsTests {
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

    @Test func reduceMotionCapsFullAtSubtle() {
        #expect(Motion.full.capped(reduceMotion: true) == .subtle)
        #expect(Motion.full.capped(reduceMotion: false) == .full)
        #expect(Motion.subtle.capped(reduceMotion: true) == .subtle)
        #expect(Motion.none.capped(reduceMotion: true) == Motion.none)
    }
}

struct CommandFlagTests {
    /// The motion is a viewing preference, set in the config or DRIP_MOTION; only the snapshot
    /// tests' `__render` takes it per card.
    @Test func motionIsASettingNotAFlag() throws {
        guard case let .exit(status, message) = CommandLineParser.parse(["ok", "t", "--motion", "none"]) else {
            Issue.record("--motion parsed"); return
        }
        #expect(status == ExitStatus.usage)
        #expect(message.hasPrefix("drip: unknown option '--motion'."), "\(message)")
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

    @Test func demoIsASubcommand() throws {
        guard case .invocation(.demo) = CommandLineParser.parse(["demo"]) else {
            Issue.record("demo did not parse"); return
        }
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

    @Test func demoDropsSeveralCards() throws {
        let cards = try DemoCommand.cards(
            CardResolver(), flags: CardFlags(id: "shared"))
        #expect(cards.map(\.kind) == ["ok", "ask", "fail", "info"])
        #expect(Set(cards.map(\.title)).count == cards.count)
        for card in cards {
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

    @Test func renderTakesATime() throws {
        guard case let .invocation(.render(command)) = CommandLineParser.parse(
            ["__render", "--out", "x.png", "ok", "t", "--at", "0.3"])
        else { Issue.record("did not parse"); return }
        #expect(command.at == 0.3)
    }
}
