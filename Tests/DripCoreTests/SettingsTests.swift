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
        ]
        for (arguments, help, expected) in commands {
            guard case let .exit(status, message) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments) parsed"); continue
            }
            let flag = arguments.first { $0 == "--position" || $0 == "--style" } ?? ""
            #expect(status == expected, "\(arguments)")
            // ArgumentParser may suggest a flag of a similar name, such as --stay for --style.
            #expect(message.hasPrefix("drip: unknown option '\(flag)'"), "\(arguments)")
            #expect(message.hasSuffix("\nSee '\(help)'."), "\(arguments)")
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

    @Test func renderTakesATime() throws {
        guard case let .invocation(.render(command)) = CommandLineParser.parse(
            ["__render", "--out", "x.png", "ok", "t", "--at", "0.3"])
        else { Issue.record("did not parse"); return }
        #expect(command.at == 0.3)
    }
}
