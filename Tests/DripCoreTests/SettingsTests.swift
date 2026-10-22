import DripCore
import Testing

/// Every card shows at the notch, drawn one way, so drip has no `position` or `style` setting: in a
/// config they are unknown keys, as flags they are unknown options, and DRIP_POSITION and
/// DRIP_STYLE are not read.
struct RemovedSettingTests {
    private let path = "/home/me/.config/drip/config.toml"

    @Test func theConfigWarnsAboutEachStaleKeyAsUnknownAndReadsTheRest() throws {
        let file = try ConfigLoader.parse("""
            style    = "glass"
            position = 3
            motion   = "subtle"

            [preset.fail]
            style = "wash"
            color = "red"
            """, path: path)
        #expect(file.warnings == [
            "\(path):1: unknown key 'style'",
            "\(path):2: unknown key 'position'",
            "\(path):6: unknown key 'preset.fail.style'",
        ])
        #expect(file.config == Config(motion: .subtle, presets: ["fail": PresetOverride(color: .system(.red))]))
    }

    /// No released drip had a `notch` key: it is unknown, as any other, and DRIP_NOTCH is not read.
    @Test func notchIsNoSetting() throws {
        let file = try ConfigLoader.parse("""
            notch    = "ears"
            motion   = "subtle"
            """, path: path)
        #expect(file.warnings == ["\(path):1: unknown key 'notch'"])
        #expect(file.config == Config(motion: .subtle))
        #expect(try ConfigLoader.parse("notch = 3", path: path).config == Config())
        #expect(try EnvironmentSettings(environment: ["DRIP_NOTCH": "drip"]) == EnvironmentSettings())
    }

    @Test func theEnvironmentIgnoresStaleVariables() throws {
        let settings = try EnvironmentSettings(environment: [
            "DRIP_STYLE": "neon", "DRIP_POSITION": "top", "DRIP_MOTION": "none",
        ])
        #expect(settings == EnvironmentSettings(motion: Motion.none))
    }

    @Test func theFlagsAreUnknownOptionsForEveryCommandThatShowsACard() {
        let commands: [([String], String, Int32)] = [
            (["ok", "t", "--position", "notch"], "drip --help", ExitStatus.usage),
            (["ok", "t", "--style", "terminal"], "drip --help", ExitStatus.usage),
            (["run", "--position", "top", "ls"], "drip run --help", ExitStatus.usage),
            (["run", "--style", "wash", "ls"], "drip run --help", ExitStatus.usage),
            (["hook", "claude", "--position", "top"], "drip hook --help", ExitStatus.hookFailed),
            (["hook", "claude", "--style", "hud"], "drip hook --help", ExitStatus.hookFailed),
            (["demo", "--position", "bottom"], "drip demo --help", ExitStatus.usage),
            (["demo", "--style", "glass"], "drip demo --help", ExitStatus.usage),
        ]
        for (arguments, help, expected) in commands {
            guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments) parsed"); continue
            }
            let flag = arguments.first { $0 == "--position" || $0 == "--style" } ?? ""
            #expect(status == expected, "\(arguments)")
            #expect(message == "drip: unknown option '\(flag)'\nSee '\(help)'.", "\(arguments)")
        }
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
