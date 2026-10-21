import DripCore
#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif
import Testing

struct ConfigTests {
    private let path = "/home/me/.config/drip/config.toml"

    @Test func theSpecExample() throws {
        let file = try ConfigLoader.parse("""
            # every key optional
            seconds  = 4.5
            position = "bottom"          # bottom | center | top
            size     = "regular"         # compact | regular | large
            sound    = true              # false mutes every preset

            [preset.ok]                  # override a built-in preset, any subset of keys
            sound = "Hero"

            [preset.deploy]              # a custom preset: drip deploy "shipped"
            icon  = "paperplane.fill"
            color = "#a78bfa"
            sound = "Submarine"
            seconds = 6
            """, path: path)
        #expect(file.warnings == [])
        #expect(file.config == Config(
            seconds: 4.5, position: .bottom, size: .regular,
            presets: [
                "ok": PresetOverride(sound: .named("Hero")),
                "deploy": PresetOverride(
                    icon: .symbol("paperplane.fill"), color: .rgb(red: 0xA7, green: 0x8B, blue: 0xFA),
                    sound: .named("Submarine"), seconds: 6),
            ]))
    }

    @Test func emptyFile() throws {
        #expect(try ConfigLoader.parse("", path: path) == ConfigFile(config: Config(), warnings: []))
    }

    @Test func overridesMergeIntoBuiltInPresets() {
        let config = Config(presets: ["ok": PresetOverride(sound: .named("Hero")), "fail": PresetOverride(seconds: 9)])
        let presets = Dictionary(uniqueKeysWithValues: config.allPresets.map { ($0.name, $0) })
        #expect(presets["ok"] == Preset(
            name: "ok", icon: .symbol("checkmark.circle.fill"), color: .system(.green), sound: .named("Hero"),
            glyph: "checkmark"))
        #expect(presets["fail"]?.seconds == 9)
        #expect(presets["warn"] == .warn)
        #expect(presets.count == 5)
    }

    @Test func customPresetsStartFromInfo() {
        let config = Config(presets: ["deploy": PresetOverride(color: .system(.purple))])
        let deploy = config.allPresets.first { $0.name == "deploy" }
        #expect(deploy == Preset(
            name: "deploy", icon: .symbol("info.circle.fill"), color: .system(.purple), sound: .named("Tink")))
    }

    @Test func presetSoundForms() throws {
        let file = try ConfigLoader.parse("""
            [preset.ok]
            sound = "none"
            [preset.warn]
            sound = false
            [preset.fail]
            sound = true
            [preset.info]
            sound = "~/sounds/ding.aiff"
            """, path: path)
        #expect(file.config.presets["ok"]?.sound == Sound.none)
        #expect(file.config.presets["warn"]?.sound == Sound.none)
        #expect(file.config.presets["fail"]?.sound == nil)
        #expect(file.config.presets["info"]?.sound == .file("~/sounds/ding.aiff"))
    }

    @Test func integerSecondsAndIconNone() throws {
        let file = try ConfigLoader.parse("seconds = 3\n[preset.ok]\nicon = \"none\"", path: path)
        #expect(file.config.seconds == 3)
        #expect(file.config.presets["ok"]?.icon == Icon.none)
    }

    @Test func anImageIconIsTakenFromTheConfigFilesDirectory() throws {
        let file = try ConfigLoader.parse("""
            [preset.ask]
            icon = "icons/agent.png"
            [preset.ok]
            icon = "app:com.openai.chat"
            [preset.fail]
            icon = "/opt/marks/fail.png"
            """, path: path)
        #expect(file.config.presets["ask"]?.icon == .image("/home/me/.config/drip/icons/agent.png"))
        #expect(file.config.presets["ok"]?.icon == .app("com.openai.chat"))
        #expect(file.config.presets["fail"]?.icon == .image("/opt/marks/fail.png"))
    }

    @Test func unknownKeysAreWarnings() throws {
        let file = try ConfigLoader.parse("""
            seconds = 2
            colour = "red"
            [preset.ok]
            sond = "Hero"
            """, path: path)
        #expect(file.config.seconds == 2)
        #expect(file.warnings == [
            "\(path):2: unknown key 'colour'",
            "\(path):4: unknown key 'preset.ok.sond'",
        ])
    }

    @Test func wrongTypesNameTheKeyAndLine() {
        assertError("seconds = \"4\"", line: 1, key: "seconds", message: "expected a number, got a string")
        assertError("\nposition = 1", line: 2, key: "position", message: "expected a string, got an integer")
        assertError("size = true", line: 1, key: "size", message: "expected a string, got a boolean")
        assertError("sound = 1", line: 1, key: "sound", message: "expected a sound name, a path, \"none\" or false, got an integer")
        assertError("preset = 1", line: 1, key: "preset", message: "expected a table, got an integer")
        assertError("[preset]\nok = \"x\"", line: 2, key: "preset.ok", message: "expected a table, got a string")
        assertError("[preset.ok]\nicon = 1", line: 2, key: "preset.ok.icon", message: "expected a string, got an integer")
        assertError("[preset.ok]\n\nseconds = true", line: 3, key: "preset.ok.seconds",
                    message: "expected a number, got a boolean")
        assertError("[preset.ok]\nsound = 1", line: 2, key: "preset.ok.sound",
                    message: "expected a sound name, a path, \"none\" or false, got an integer")
    }

    @Test func invalidValuesNameTheKeyAndLine() {
        assertError("seconds = 0.4", line: 1, key: "seconds", message: "must be between 0.5 and 60")
        assertError("seconds = 61", line: 1, key: "seconds", message: "must be between 0.5 and 60")
        assertError("position = \"left\"", line: 1, key: "position",
                    message: "expected bottom, center, top or notch, got 'left'")
        assertError("size = \"huge\"", line: 1, key: "size", message: "expected compact, regular or large, got 'huge'")
        assertError("style = \"neon\"", line: 1, key: "style", message: "expected hud, glass, wash or terminal, got 'neon'")
        assertError("motion = \"lots\"", line: 1, key: "motion", message: "expected full, subtle or none, got 'lots'")
        assertError("[preset.fail]\nstyle = \"neon\"", line: 2, key: "preset.fail.style",
                    message: "expected hud, glass, wash or terminal, got 'neon'")
        assertError("[preset.demo]\nicon = \"x\"", line: 1, key: "preset.demo",
                    message: "'demo' is kept for drip's own commands; give the preset another name")
        assertError("stack = \"stacked\"", line: 1, key: "stack", message: "expected chain, push or off, got 'stacked'")
        assertError("[preset.ok]\nicon = \"app:\"", line: 2, key: "preset.ok.icon",
                    message: "'app:' does not name an app by its bundle identifier, such as app:com.apple.Terminal")
        assertError("[preset.ok]\ncolor = \"teal\"", line: 2, key: "preset.ok.color",
                    message: "expected #rrggbb or one of green, orange, red, blue, purple, pink, yellow or gray, got 'teal'")
    }

    @Test func customPresetNames() throws {
        for name in ["deploy", "a", "ci-2", "x9"] {
            #expect(try ConfigLoader.parse("[preset.\(name)]\nicon = \"star\"", path: path).config.presets[name] != nil)
        }
        for name in ["Deploy", "2fa", "-x", "a_b"] {
            assertError("\n[preset.\(name)]", line: 2, key: "preset.\(name)", message: "a custom preset name must match")
        }
    }

    /// `drip <name>` runs a subcommand by that name instead, so a preset cannot take the names of
    /// drip's subcommands, or of those it may have later.
    @Test func subcommandNamesAreReserved() {
        for name in ["run", "hook", "demo", "history", "show", "help", "version", "setup", "config", "init", "install",
                     "uninstall", "completion", "completions", "doctor", "mute", "pause", "listen", "test"] {
            assertError("\n[preset.\(name)]", line: 2, key: "preset.\(name)", message: "'\(name)' is kept for drip's own commands")
        }
    }

    /// The top-level sound takes a name, a path or none, as DRIP_SOUND does, or false, which mutes.
    @Test func topLevelSound() throws {
        #expect(try ConfigLoader.parse("sound = \"Hero\"", path: path).config.sound == .named("Hero"))
        #expect(try ConfigLoader.parse("sound = \"~/ding.aiff\"", path: path).config.sound == .file("~/ding.aiff"))
        #expect(try ConfigLoader.parse("sound = \"none\"", path: path).config.sound == Sound.none)
        #expect(try ConfigLoader.parse("sound = false", path: path).config.sound == Sound.none)
        #expect(try ConfigLoader.parse("sound = true", path: path).config == Config())
    }

    @Test func syntaxErrorsNameTheLine() {
        assertError("seconds = 4.5\nposition = ", line: 2, key: nil, message: "expected a value")
        assertError("[preset.ok]\nsound = \"Hero\"\n[[preset]]", line: 3, key: nil,
                    message: "arrays of tables are not supported")
        assertError("seconds = 3\npreset.ok.icon = \"star\"", line: 2, key: nil,
                    message: "dotted keys are not supported")
    }

    @Test func configPath() {
        #expect(ConfigLoader.path(environment: ["XDG_CONFIG_HOME": "/x", "HOME": "/home/me"]) == "/x/drip/config.toml")
        #expect(ConfigLoader.path(environment: ["HOME": "/home/me"]) == "/home/me/.config/drip/config.toml")
        #expect(ConfigLoader.path(environment: ["XDG_CONFIG_HOME": "", "HOME": "/home/me"]) == "/home/me/.config/drip/config.toml")
        #expect(ConfigLoader.path(environment: ["XDG_CONFIG_HOME": "relative", "HOME": "/home/me"]) == "/home/me/.config/drip/config.toml")
    }

    @Test func loadReadsTheFileAndAcceptsAMissingOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("drip-config-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["XDG_CONFIG_HOME": directory.path]
        #expect(try ConfigLoader.load(environment: environment).config == Config())

        let drip = directory.appendingPathComponent("drip")
        try FileManager.default.createDirectory(at: drip, withIntermediateDirectories: true)
        try Data("size = \"large\"\n".utf8).write(to: drip.appendingPathComponent("config.toml"))
        #expect(try ConfigLoader.load(environment: environment).config == Config(size: .large))

        try Data([0xFF, 0xFE]).write(to: drip.appendingPathComponent("config.toml"))
        let error = #expect(throws: ConfigError.self) { try ConfigLoader.load(environment: environment) }
        #expect(error?.message == "the file is not UTF-8")

        try Data(repeating: UInt8(ascii: "#"), count: ConfigLoader.sizeLimit + 1)
            .write(to: drip.appendingPathComponent("config.toml"))
        let huge = #expect(throws: ConfigError.self) { try ConfigLoader.load(environment: environment) }
        #expect(huge?.message == "the file is larger than 1 MB")
    }

    @Test func errorDescription() {
        let error = ConfigError(path: path, line: 3, key: "seconds", message: "expected a number, got a string")
        #expect(error.description == "\(path):3: seconds: expected a number, got a string")
        #expect(ConfigError(path: path, line: nil, key: nil, message: "cannot read the file").description == "\(path): cannot read the file")
    }

    private func assertError(
        _ text: String, line: Int, key: String?, message: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let error = #expect(throws: ConfigError.self, sourceLocation: sourceLocation) {
            try ConfigLoader.parse(text, path: path)
        }
        guard let error else { return }
        #expect(error.path == path, sourceLocation: sourceLocation)
        #expect(error.line == line, "\(error)", sourceLocation: sourceLocation)
        #expect(error.key == key, "\(error)", sourceLocation: sourceLocation)
        #expect(error.message.hasPrefix(message), "\(error)", sourceLocation: sourceLocation)
    }
}

struct PrecedenceTests {
    @Test func environmentSettings() throws {
        #expect(try EnvironmentSettings(environment: [:]) == EnvironmentSettings())
        #expect(try EnvironmentSettings(environment: [
                "DRIP_SECONDS": "2", "DRIP_POSITION": "top", "DRIP_SIZE": "compact", "DRIP_SOUND": "none",
            ]) == EnvironmentSettings(seconds: 2, position: .top, size: .compact, sound: Sound.none))
        #expect(try EnvironmentSettings(environment: ["DRIP_SECONDS": ""]) == EnvironmentSettings())
        #expect(try EnvironmentSettings(environment: ["DRIP_STACK": "off", "DRIP_STACK_MAX": "6"])
            == EnvironmentSettings(stack: .off, stackMax: 6))
        for (name, value) in [("DRIP_SECONDS", "abc"), ("DRIP_SECONDS", "99"), ("DRIP_POSITION", "left"),
                              ("DRIP_SIZE", "huge"), ("DRIP_STACK", "psuh"), ("DRIP_STACK", "Push"),
                              ("DRIP_STACK_MAX", "0"), ("DRIP_STACK_MAX", "7"), ("DRIP_STACK_MAX", "2.5"),
                              ("DRIP_STACK_MAX", "many")] {
            let error = #expect(throws: UsageError.self) { try EnvironmentSettings(environment: [name: value]) }
            #expect(error?.message.hasPrefix(name) == true)
        }
    }

    @Test func defaultsWhenNothingIsSet() throws {
        let card = try CardResolver().resolve(kind: "ok", title: "t", flags: CardFlags())
        #expect(card.seconds == 4.5)
        #expect(card.position == .notch)
        #expect(card.size == .regular)
        #expect(card.sound == .named("Glass"))
    }

    @Test func configBeatsDefaults() throws {
        let config = Config(seconds: 3, position: .center, size: .large)
        let card = try CardResolver(config: config).resolve(kind: "ok", title: "t", flags: CardFlags())
        #expect(card.seconds == 3)
        #expect(card.position == .center)
        #expect(card.size == .large)
    }

    @Test func presetSecondsBeatGlobalConfigSeconds() throws {
        let config = Config(seconds: 3, presets: ["fail": PresetOverride(seconds: 8)])
        let resolver = CardResolver(config: config)
        #expect(try resolver.resolve(kind: "fail", title: "t", flags: CardFlags()).seconds == 8)
        #expect(try resolver.resolve(kind: "ok", title: "t", flags: CardFlags()).seconds == 3)
    }

    @Test func environmentBeatsConfig() throws {
        let config = Config(seconds: 3, position: .center, size: .large, presets: ["ok": PresetOverride(seconds: 9)])
        let environment = EnvironmentSettings(seconds: 2, position: .top, size: .compact, sound: .named("Ping"))
        let card = try CardResolver(config: config, environment: environment)
            .resolve(kind: "ok", title: "t", flags: CardFlags())
        #expect(card.seconds == 2)
        #expect(card.position == .top)
        #expect(card.size == .compact)
        #expect(card.sound == .named("Ping"))
    }

    @Test func flagsBeatEnvironment() throws {
        let environment = EnvironmentSettings(seconds: 2, position: .top, size: .compact, sound: Sound.none)
        let flags = CardFlags(seconds: 7, sound: .named("Hero"), position: .bottom, size: .regular)
        let card = try CardResolver(config: Config(seconds: 3), environment: environment)
            .resolve(kind: "ok", title: "t", flags: flags)
        #expect(card.seconds == 7)
        #expect(card.position == .bottom)
        #expect(card.size == .regular)
        #expect(card.sound == .named("Hero"))
    }

    @Test func configSoundFalseMutesEveryPreset() throws {
        let config = Config(sound: Sound.none, presets: ["ok": PresetOverride(sound: .named("Hero"))])
        let resolver = CardResolver(config: config)
        for kind in ["ok", "warn", "fail", "info"] {
            #expect(try resolver.resolve(kind: kind, title: "t", flags: CardFlags()).sound == Sound.none)
        }
        #expect(try resolver.resolve(kind: "ok", title: "t", flags: CardFlags(sound: .named("Pop"))).sound == .named("Pop"))
        let unmuted = CardResolver(config: config, environment: EnvironmentSettings(sound: .named("Ping")))
        #expect(try unmuted.resolve(kind: "ok", title: "t", flags: CardFlags()).sound == .named("Ping"))
    }

    /// A sound named at the top level is every preset's, unless the preset sets its own.
    @Test func configSoundNameReplacesThePresetsSounds() throws {
        let config = Config(sound: .named("Pop"), presets: ["ok": PresetOverride(sound: .named("Hero"))])
        let resolver = CardResolver(config: config)
        #expect(try resolver.resolve(kind: "ok", title: "t", flags: CardFlags()).sound == .named("Hero"))
        for kind in ["warn", "fail", "info", "ask"] {
            #expect(try resolver.resolve(kind: kind, title: "t", flags: CardFlags()).sound == .named("Pop"))
        }
        #expect(try resolver.resolve(kind: "fail", title: "t", flags: CardFlags(sound: .named("Ping"))).sound == .named("Ping"))
    }

    @Test func dripSoundNoneMutes() throws {
        let resolver = CardResolver(environment: EnvironmentSettings(sound: Sound.none))
        #expect(try resolver.resolve(kind: "fail", title: "t", flags: CardFlags()).sound == Sound.none)
    }

    @Test func customPresetEndToEnd() throws {
        let file = try ConfigLoader.parse("""
            [preset.deploy]
            icon  = "paperplane.fill"
            color = "#a78bfa"
            sound = "Submarine"
            seconds = 6
            """, path: "config.toml")
        let resolver = CardResolver(config: file.config)
        let card = try resolver.resolve(kind: "deploy", title: "shipped", flags: CardFlags())
        #expect(card == Card(
            kind: "deploy", title: "shipped", icon: .symbol("paperplane.fill"),
            color: .rgb(red: 0xA7, green: 0x8B, blue: 0xFA), sound: .named("Submarine"), seconds: 6))
        // Without the config, deploy is just a title.
        #expect(try CardResolver().resolve(kind: "deploy", title: nil, flags: CardFlags()).title == "deploy")
    }

    @Test func anAskCardWaitsUnlessATimeIsSet() throws {
        let waiting = try CardResolver().resolve(kind: "ask", title: "t", flags: CardFlags())
        #expect(waiting.waitLimit == Defaults.waitLimit)
        // A time from the command line, the environment or the preset makes it count down.
        let flagged = try CardResolver().resolve(kind: "ask", title: "t", flags: CardFlags(seconds: 8))
        #expect(flagged.waitLimit == nil && flagged.seconds == 8)
        let environment = try CardResolver(environment: EnvironmentSettings(seconds: 5))
            .resolve(kind: "ask", title: "t", flags: CardFlags())
        #expect(environment.waitLimit == nil && environment.seconds == 5)
        let preset = try CardResolver(config: Config(presets: ["ask": PresetOverride(seconds: 9)]))
            .resolve(kind: "ask", title: "t", flags: CardFlags())
        #expect(preset.waitLimit == nil && preset.seconds == 9)
        // The top-level seconds is every card's time, and an ask card still waits.
        let global = try CardResolver(config: Config(seconds: 3)).resolve(kind: "ask", title: "t", flags: CardFlags())
        #expect(global.waitLimit == Defaults.waitLimit)
        // Other presets never wait.
        for kind in ["ok", "warn", "fail", "info"] {
            #expect(try CardResolver().resolve(kind: kind, title: "t", flags: CardFlags()).waitLimit == nil)
        }
    }

    @Test func overriddenBuiltInPresetDrivesDripRun() throws {
        let config = Config(presets: ["ok": PresetOverride(sound: .named("Hero")), "fail": PresetOverride(seconds: 10)])
        let resolver = CardResolver(config: config)
        #expect(try resolver.resolveRun(command: ["true"], status: 0, seconds: 1, flags: CardFlags()).sound == .named("Hero"))
        #expect(try resolver.resolveRun(command: ["false"], status: 1, seconds: 1, flags: CardFlags()).seconds == 10)
    }
}

struct StackSettingsTests {
    private let path = "/home/me/.config/drip/config.toml"

    @Test func configReadsStackMaxWithinRange() throws {
        #expect(try ConfigLoader.parse("stack_max = 5", path: path).config.stackMax == 5)
        let tooMany = #expect(throws: ConfigError.self) { try ConfigLoader.parse("stack_max = 7", path: path) }
        #expect(tooMany?.description == "\(path):1: stack_max: must be between 1 and 6")
        let text = #expect(throws: ConfigError.self) { try ConfigLoader.parse("stack_max = \"3\"", path: path) }
        #expect(text?.description == "\(path):1: stack_max: expected a whole number, got a string")
    }

    @Test func configReadsTheStack() throws {
        #expect(try ConfigLoader.parse("stack = \"push\"", path: path) == ConfigFile(config: Config(stack: .push), warnings: []))
        #expect(try ConfigLoader.parse("stack = \"off\"", path: path).config.stack == .off)
    }

    @Test func stackMaxComesFromTheEnvironmentThenTheConfigThenThree() {
        let config = Config(stackMax: 5)
        #expect(StackSettings.current(environment: [:], config: Config()) == StackSettings(mode: .chain, max: 3))
        #expect(StackSettings.current(environment: [:], config: config)?.max == 5)
        #expect(StackSettings.current(environment: ["DRIP_STACK_MAX": "2"], config: config)?.max == 2)
    }

    @Test func stackModeComesFromTheEnvironmentThenTheConfig() {
        #expect(StackSettings.current(environment: ["DRIP_STACK": "push"], config: Config())?.mode == .push)
        #expect(StackSettings.current(environment: ["DRIP_STACK": "off"], config: Config()) == nil)
        #expect(StackSettings.current(environment: [:], config: Config(stack: .push))?.mode == .push)
        #expect(StackSettings.current(environment: [:], config: Config(stack: .off)) == nil)
        #expect(StackSettings.current(environment: ["DRIP_STACK": "chain"], config: Config(stack: .off))?.mode == .chain)
    }

    /// A drip with a bad DRIP_STACK or DRIP_STACK_MAX exits 2 before it hands off a card, so the
    /// drip that shows the cards falls back to the defaults.
    @Test func invalidStackSettingsAreLeftOut() {
        #expect(StackSettings.current(environment: ["DRIP_STACK": "psuh"], config: Config()) == StackSettings(mode: .chain, max: 3))
        #expect(StackSettings.current(environment: ["DRIP_STACK_MAX": "40"], config: Config(stackMax: 5))?.max == 5)
    }

    @Test func aModeGivenOverridesTheEnvironment() {
        #expect(StackSettings.current(environment: ["DRIP_STACK": "off"], config: Config(), mode: .push)
            == StackSettings(mode: .push, max: 3))
        #expect(StackSettings.current(environment: ["DRIP_STACK": "push"], config: Config(), mode: .chain)?.mode == .chain)
    }
}
