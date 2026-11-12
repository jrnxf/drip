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
            seconds: 4.5, size: .regular,
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
        #expect(presets.count == 4)
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
            [preset.agent]
            icon = "icons/agent.png"
            [preset.ok]
            icon = "app:com.openai.chat"
            [preset.fail]
            icon = "/opt/marks/fail.png"
            """, path: path)
        #expect(file.config.presets["agent"]?.icon == .image("/home/me/.config/drip/icons/agent.png"))
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

    @Test func contrastIsABoolean() throws {
        #expect(try ConfigLoader.parse("contrast = true", path: path).config == Config(contrast: true))
        #expect(try ConfigLoader.parse("contrast = false", path: path).config == Config(contrast: false))
        #expect(try ConfigLoader.parse("", path: path).config.contrast == nil)
        assertError("contrast = \"high\"", line: 1, key: "contrast", message: "expected true or false, got a string")
    }

    @Test func wrongTypesNameTheKeyAndLine() {
        assertError("seconds = \"4\"", line: 1, key: "seconds", message: "expected a number, got a string")
        assertError("\nmotion = 1", line: 2, key: "motion", message: "expected a string, got an integer")
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
        assertError("size = \"huge\"", line: 1, key: "size", message: "expected compact, regular or large, got 'huge'")
        assertError("motion = \"lots\"", line: 1, key: "motion", message: "expected full, subtle or none, got 'lots'")
        assertError("[preset.history]\nicon = \"x\"", line: 1, key: "preset.history",
                    message: "'history' is kept for drip's own commands; give the preset another name")
        assertError("stack = \"stacked\"", line: 1, key: "stack", message: "expected chain or off, got 'stacked'")
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
        for name in ConfigLoader.reservedNames.sorted() {
            assertError("\n[preset.\(name)]", line: 2, key: "preset.\(name)", message: "'\(name)' is kept for drip's own commands")
        }
    }

    /// Every subcommand and alias is reserved, so a new subcommand cannot be forgotten.
    @Test func everySubcommandIsReserved() {
        for command in DripCommand.configuration.subcommands {
            for name in [command.configuration.commandName].compactMap({ $0 }) + command.configuration.aliases
            where !name.hasPrefix("_") {
                #expect(ConfigLoader.reservedNames.contains(name), "\(name)")
            }
        }
    }

    /// Names of commands drip does not have are free for a preset.
    @Test func namesOfNoCommandAreFree() throws {
        for name in ["init", "install", "uninstall", "listen", "setup", "mute"] {
            _ = try ConfigLoader.parse("\n[preset.\(name)]\ntitle = \"x\"\n", path: path)
        }
    }

    #if !os(WASI)
    @Test func theDocsListTheReservedNames() throws {
        let text = try String(contentsOf: DripProcess.repo.appendingPathComponent("docs/config.md"), encoding: .utf8)
        let start = try #require(text.range(of: "name kept for them:"))
        let end = try #require(text.range(of: "A custom preset's ring", range: start.upperBound..<text.endIndex))
        let listed = text[start.upperBound..<end.lowerBound].split(separator: "`").enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
        #expect(Set(listed) == ConfigLoader.reservedNames)
        #expect(listed.count == ConfigLoader.reservedNames.count)
    }
    #endif

    /// The top-level sound takes a name, a path or none, as DRIP_SOUND does, or false, which mutes.
    @Test func topLevelSound() throws {
        #expect(try ConfigLoader.parse("sound = \"Hero\"", path: path).config.sound == .named("Hero"))
        #expect(try ConfigLoader.parse("sound = \"~/ding.aiff\"", path: path).config.sound == .file("~/ding.aiff"))
        #expect(try ConfigLoader.parse("sound = \"none\"", path: path).config.sound == Sound.none)
        #expect(try ConfigLoader.parse("sound = false", path: path).config.sound == Sound.none)
        #expect(try ConfigLoader.parse("sound = true", path: path).config == Config())
    }

    /// Dotted keys and inline tables read as the same preset as a `[preset.ci]` table.
    @Test func dottedKeysAndInlineTablesReadLikeTables() throws {
        let expected = try ConfigLoader.parse("[preset.ci]\nsound = \"Hero\"\nseconds = 3", path: path)
        #expect(expected.config.presets["ci"]?.sound == .named("Hero"))
        for text in [
            "preset.ci.sound = \"Hero\"\npreset.ci.seconds = 3",
            "[preset]\nci.sound = \"Hero\"\nci.seconds = 3",
            "[preset]\nci = { sound = \"Hero\", seconds = 3 }",
            "preset = { ci = { sound = \"Hero\", seconds = 3 } }",
        ] {
            let file = try ConfigLoader.parse(text, path: path)
            #expect(file.config == expected.config, "\(text.debugDescription)")
            #expect(file.warnings.isEmpty)
        }
        // A bad field in a dotted key warns, and the other fields stay.
        let file = ConfigLoader.parseLeniently(
            "preset.ci.sound = \"Hero\"\npreset.ci.seconds = \"x\"\nsize.big = 1", path: path)
        #expect(file.config.presets["ci"]?.sound == .named("Hero"))
        #expect(file.problems.map(\.key) == ["preset.ci.seconds", "size"])
        #expect(file.problems.map(\.line) == [2, 3])
    }

    @Test func syntaxErrorsNameTheLine() {
        assertError("seconds = 4.5\nsize = ", line: 2, key: nil, message: "expected a value")
        assertError("[preset.ok]\nsound = \"Hero\"\n[[preset]]", line: 3, key: nil,
                    message: "arrays of tables are not supported")
        assertError("seconds = 3\nt = { a = 1", line: 2, key: nil, message: "unterminated inline table")
        assertError("[preset]\nci.sound = \"Hero\"\n[preset.ci]", line: 3, key: nil, message: "table 'preset.ci' is already defined")
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

    /// A card command reads the config leniently: each bad key keeps its default, with a warning,
    /// and the good keys around it still apply.
    @Test func aLenientParseLeavesOutOnlyTheBadKeys() {
        let file = ConfigLoader.parseLeniently("""
            seconds = "five"
            size = "large"
            nope = 1
            [preset.ok]
            color = "plaid"
            sound = "none"
            [preset.run]
            icon = "star"
            [preset.mine]
            color = "red"
            """, path: path)
        #expect(file.config == Config(size: .large, presets: [
            "ok": PresetOverride(sound: Sound.none),
            "mine": PresetOverride(color: CardColor(parsing: "red")),
        ]))
        #expect(file.problems.map(\.key) == ["seconds", "preset.ok.color", "preset.run"])
        #expect(file.problems.map(\.line) == [1, 5, 7])
        #expect(file.warnings.count == 4)
        #expect(file.warnings[0] == "invalid config: \(path):1: seconds: expected a number, got a string (drip ignores this key)")
        #expect(file.warnings[1] == "\(path):3: unknown key 'nope'")
        #expect(file.warnings[2].hasPrefix("invalid config: \(path):5: preset.ok.color: expected #rrggbb"))
        #expect(file.warnings[3].hasSuffix("(drip ignores this key)"))
        // A strict parse, for a command that checks the file, throws the first of them.
        let error = #expect(throws: ConfigError.self) { try ConfigLoader.parse("seconds = \"five\"\nsize = 3", path: path) }
        #expect(error?.key == "seconds")
    }

    /// A file that is not TOML drip reads leaves every key at its default.
    @Test func aLenientParseOfABrokenFileKeepsEveryDefault() {
        let file = ConfigLoader.parseLeniently("size = \"large\"\nbroken = [", path: path)
        #expect(file.config == Config())
        #expect(file.problems.count == 1)
        #expect(file.problems.first?.key == nil)
        #expect(file.warnings.count == 1)
        #expect(file.warnings.first?.hasPrefix("invalid config: \(path):") == true)
        #expect(file.warnings.first?.hasSuffix("(drip ignores the file)") == true)
        #expect(ConfigLoader.parseLeniently("", path: path) == ConfigFile(config: Config(), warnings: []))
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
                "DRIP_SECONDS": "2", "DRIP_SIZE": "compact", "DRIP_SOUND": "none",
            ]) == EnvironmentSettings(seconds: 2, size: .compact, sound: Sound.none))
        #expect(try EnvironmentSettings(environment: ["DRIP_SECONDS": ""]) == EnvironmentSettings())
        #expect(try EnvironmentSettings(environment: ["DRIP_STACK": "off", "DRIP_STACK_MAX": "6"])
            == EnvironmentSettings(stack: .off, stackMax: 6))
        #expect(try EnvironmentSettings(environment: ["DRIP_DEBUG": "1"]) == EnvironmentSettings(debug: true))
        #expect(try EnvironmentSettings(environment: ["DRIP_DEBUG": "off"]) == EnvironmentSettings(debug: false))
        #expect(try EnvironmentSettings(environment: ["DRIP_DEBUG": ""]) == EnvironmentSettings())
        #expect(try EnvironmentSettings(environment: ["DRIP_CONTRAST": "1"]) == EnvironmentSettings(contrast: true))
        #expect(try EnvironmentSettings(environment: ["DRIP_CONTRAST": "0"]) == EnvironmentSettings(contrast: false))
        #expect(try EnvironmentSettings(environment: ["DRIP_CONTRAST": ""]) == EnvironmentSettings())
        for (name, value) in [("DRIP_SECONDS", "abc"), ("DRIP_SECONDS", "99"), ("DRIP_MOTION", "lots"),
                              ("DRIP_SIZE", "huge"), ("DRIP_STACK", "psuh"), ("DRIP_STACK", "Push"),
                              ("DRIP_STACK_MAX", "0"), ("DRIP_STACK_MAX", "7"), ("DRIP_STACK_MAX", "2.5"),
                              ("DRIP_STACK_MAX", "many"), ("DRIP_DEBUG", "maybe"),
                              ("DRIP_CONTRAST", "hairline")] {
            let error = #expect(throws: UsageError.self) { try EnvironmentSettings(environment: [name: value]) }
            #expect(error?.message.hasPrefix(name) == true)
        }
    }

    @Test func defaultsWhenNothingIsSet() throws {
        let card = try CardResolver().resolve(kind: "ok", title: "t", flags: CardFlags())
        #expect(card.seconds == 4.5)
        #expect(card.size == .regular)
        #expect(card.sound == .named("Glass"))
    }

    @Test func configBeatsDefaults() throws {
        let config = Config(seconds: 3, size: .large)
        let card = try CardResolver(config: config).resolve(kind: "ok", title: "t", flags: CardFlags())
        #expect(card.seconds == 3)
        #expect(card.size == .large)
    }

    @Test func presetSecondsBeatGlobalConfigSeconds() throws {
        let config = Config(seconds: 3, presets: ["fail": PresetOverride(seconds: 8)])
        let resolver = CardResolver(config: config)
        #expect(try resolver.resolve(kind: "fail", title: "t", flags: CardFlags()).seconds == 8)
        #expect(try resolver.resolve(kind: "ok", title: "t", flags: CardFlags()).seconds == 3)
    }

    @Test func environmentBeatsConfig() throws {
        let config = Config(seconds: 3, size: .large, presets: ["ok": PresetOverride(seconds: 9)])
        let environment = EnvironmentSettings(seconds: 2, size: .compact, sound: .named("Ping"))
        let card = try CardResolver(config: config, environment: environment)
            .resolve(kind: "ok", title: "t", flags: CardFlags())
        #expect(card.seconds == 2)
        #expect(card.size == .compact)
        #expect(card.sound == .named("Ping"))
    }

    /// The card carries true or nothing, so a card without the outline reads and writes as before.
    @Test func contrastComesFromTheEnvironmentThenTheConfig() throws {
        func contrast(_ config: Config, _ environment: EnvironmentSettings = EnvironmentSettings()) throws -> Bool? {
            try CardResolver(config: config, environment: environment)
                .resolve(kind: "ok", title: "t", flags: CardFlags()).contrast
        }
        #expect(try contrast(Config()) == nil)
        #expect(try contrast(Config(contrast: false)) == nil)
        #expect(try contrast(Config(contrast: true)) == true)
        #expect(try contrast(Config(), EnvironmentSettings(contrast: true)) == true)
        #expect(try contrast(Config(contrast: true), EnvironmentSettings(contrast: false)) == nil)
        #expect(try contrast(Config(contrast: false), EnvironmentSettings(contrast: true)) == true)
    }

    @Test func flagsBeatEnvironment() throws {
        let environment = EnvironmentSettings(seconds: 2, size: .compact, sound: Sound.none)
        let flags = CardFlags(seconds: 7, sound: .named("Hero"), size: .regular)
        let card = try CardResolver(config: Config(seconds: 3), environment: environment)
            .resolve(kind: "ok", title: "t", flags: flags)
        #expect(card.seconds == 7)
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
        for kind in ["warn", "fail", "info"] {
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

    @Test func aCardThatStaysWaitsUnlessATimeIsSet() throws {
        let stay = CardFlags(stay: true)
        let waiting = try CardResolver().resolve(kind: "fail", title: "t", flags: stay)
        #expect(waiting.waitLimit == Defaults.waitLimit)
        // A time from the command line, the environment or the preset makes it count down.
        let flagged = try CardResolver().resolve(kind: "fail", title: "t", flags: CardFlags(seconds: 8, stay: true))
        #expect(flagged.waitLimit == nil && flagged.seconds == 8)
        let environment = try CardResolver(environment: EnvironmentSettings(seconds: 5))
            .resolve(kind: "fail", title: "t", flags: stay)
        #expect(environment.waitLimit == nil && environment.seconds == 5)
        let preset = try CardResolver(config: Config(presets: ["fail": PresetOverride(seconds: 9)]))
            .resolve(kind: "fail", title: "t", flags: stay)
        #expect(preset.waitLimit == nil && preset.seconds == 9)
        // The top-level seconds is every card's time, and a card that stays still waits.
        let global = try CardResolver(config: Config(seconds: 3)).resolve(kind: "fail", title: "t", flags: stay)
        #expect(global.waitLimit == Defaults.waitLimit)
        // Without --stay, no built-in look waits.
        for kind in ["ok", "warn", "fail", "info"] {
            #expect(try CardResolver().resolve(kind: kind, title: "t", flags: CardFlags()).waitLimit == nil)
        }
    }

    @Test func aQuestionOfAnyKindWaitsUnlessATimeIsSet() throws {
        let asked = CardFlags(button: "Deploy", decline: "Cancel")
        for kind in ["ok", "warn", "fail", "info"] {
            let card = try CardResolver().resolve(kind: kind, title: "deploy to prod?", flags: asked)
            #expect(card.waitLimit == Defaults.waitLimit && card.waitsForAnswer)
        }
        // A time from the command line, the environment or the preset gives it a deadline instead.
        var deadline = asked
        deadline.seconds = 10
        let flagged = try CardResolver().resolve(kind: "warn", title: "t", flags: deadline)
        #expect(flagged.waitLimit == nil && flagged.seconds == 10 && flagged.asksQuestion)
        let environment = try CardResolver(environment: EnvironmentSettings(seconds: 5))
            .resolve(kind: "warn", title: "t", flags: asked)
        #expect(environment.waitLimit == nil && environment.seconds == 5)
        let preset = try CardResolver(config: Config(presets: ["warn": PresetOverride(seconds: 9)]))
            .resolve(kind: "warn", title: "t", flags: asked)
        #expect(preset.waitLimit == nil && preset.seconds == 9)
        let global = try CardResolver(config: Config(seconds: 3)).resolve(kind: "warn", title: "t", flags: asked)
        #expect(global.waitLimit == Defaults.waitLimit)
        // A button that opens something is no question, and counts down.
        let open = try CardResolver().resolve(
            kind: "ok", title: "t", flags: CardFlags(open: "https://example.com", button: "View"))
        #expect(open.waitLimit == nil && !open.asksQuestion)
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
        #expect(try ConfigLoader.parse("stack = \"chain\"", path: path) == ConfigFile(config: Config(stack: .chain), warnings: []))
        #expect(try ConfigLoader.parse("stack = \"off\"", path: path).config.stack == .off)
    }

    /// A config written for the push stack drip once had still loads: its cards stack, with a warning.
    @Test func aRetiredStackValueStacksWithAWarning() throws {
        let file = try ConfigLoader.parse("seconds = 3\nstack = \"push\"", path: path)
        #expect(file.config == Config(seconds: 3, stack: .chain))
        #expect(file.warnings == ["\(path):2: stack = \"push\" is gone, cards stack as \"chain\""])
        #expect(file.problems.isEmpty)
        #expect(try stack(["DRIP_STACK": "push"], Config(stack: .off)) == StackSettings(max: 3))
    }

    /// The stack as `DRIP_STACK` and `DRIP_STACK_MAX` set it, then the config.
    private func stack(_ environment: [String: String], _ config: Config) throws -> StackSettings? {
        CardResolver(config: config, environment: try EnvironmentSettings(environment: environment)).stack
    }

    @Test func stackDelayIsASmallNumberOfSecondsInTheConfigAndTheEnvironment() throws {
        let path = "config.toml"
        #expect(try ConfigLoader.parse("stack_delay = 0.4", path: path).config.stackDelay == 0.4)
        #expect(try ConfigLoader.parse("stack_delay = 1", path: path).config.stackDelay == 1)
        #expect(try ConfigLoader.parse("stack_delay = 0", path: path).config.stackDelay == 0)
        let tooLong = #expect(throws: ConfigError.self) { try ConfigLoader.parse("stack_delay = 6", path: path) }
        #expect(tooLong?.description == "\(path):1: stack_delay: must be between 0 and 5")
        let text = #expect(throws: ConfigError.self) { try ConfigLoader.parse("stack_delay = \"1\"", path: path) }
        #expect(text?.description == "\(path):1: stack_delay: expected a number, got a string")
        #expect(try EnvironmentSettings(environment: ["DRIP_STACK_DELAY": "0.25"]).stackDelay == 0.25)
        #expect(try EnvironmentSettings(environment: ["DRIP_STACK_DELAY": ""]).stackDelay == nil)
        #expect(throws: UsageError.self) { try EnvironmentSettings(environment: ["DRIP_STACK_DELAY": "9"]) }
        // The environment first, then the config; nothing set leaves the stack to settle.
        let config = Config(stackDelay: 0.5)
        #expect(StackSettings.delay(EnvironmentSettings(stackDelay: 0.2), config: config) == 0.2)
        #expect(StackSettings.delay(EnvironmentSettings(), config: config) == 0.5)
        #expect(StackSettings.delay(EnvironmentSettings(), config: Config()) == nil)
        #expect(StackSettings.resolved(EnvironmentSettings(), config: config)?.delay == 0.5)
    }

    @Test func stackMaxComesFromTheEnvironmentThenTheConfigThenThree() throws {
        let config = Config(stackMax: 5)
        #expect(try stack([:], Config()) == StackSettings(max: 3))
        #expect(try stack([:], config)?.max == 5)
        #expect(try stack(["DRIP_STACK_MAX": "2"], config)?.max == 2)
    }

    @Test func stackingComesFromTheEnvironmentThenTheConfig() throws {
        #expect(try stack(["DRIP_STACK": "off"], Config()) == nil)
        #expect(try stack([:], Config(stack: .chain)) != nil)
        #expect(try stack([:], Config(stack: .off)) == nil)
        #expect(try stack(["DRIP_STACK": "chain"], Config(stack: .off)) != nil)
    }

    /// `drip run` and a replay show their card whatever the environment says: each `DRIP_*`
    /// variable drip cannot read is left out, and the config and the other variables still apply.
    @Test func invalidStackSettingsAreLeftOut() {
        let file = ConfigFile(config: Config(stack: .chain, stackMax: 5), warnings: ["a key drip ignores"])
        let load = { (_: [String: String]) in file }
        let psuh = CardResolver.leniently(environment: ["DRIP_STACK": "psuh", "DRIP_STACK_MAX": "2"], loadConfig: load)
        #expect(psuh.resolver.stack == StackSettings(max: 2))
        #expect(psuh.warnings == ["a key drip ignores"])
        // The error is the one a card command reports.
        #expect((psuh.error as? UsageError)?.message.hasPrefix("DRIP_STACK must be ") == true)
        let tooMany = CardResolver.leniently(environment: ["DRIP_STACK": "chain", "DRIP_STACK_MAX": "40"], loadConfig: load)
        #expect(tooMany.resolver.stack == StackSettings(max: 5))
        let fine = CardResolver.leniently(environment: [:], loadConfig: load)
        #expect(fine.resolver.stack == StackSettings(max: 5))
        #expect(fine.error == nil)
    }

    /// Each `DRIP_*` variable is either in the settings or has a problem: none goes without a word.
    @Test func eachVariableIsKeptOrHasAProblem() {
        let (settings, problems) = EnvironmentSettings.leniently([
            "DRIP_STACK": "off", "DRIP_STACK_MAX": "40", "DRIP_HISTORY": "lots", "DRIP_SECONDS": "5",
        ])
        #expect(settings.stack == .off)
        #expect(settings.seconds == 5)
        #expect(settings.stackMax == nil)
        #expect(settings.history == nil)
        #expect(problems.count == 2)
        #expect(problems.allSatisfy { $0.hasPrefix("DRIP_HISTORY") || $0.hasPrefix("DRIP_STACK_MAX") })
    }

    #if !os(WASI) // An agent's hook does not run on WebAssembly.
    /// A card reads the config once: where its drip makes it. The drip that shows it takes the
    /// settings from the request, and reads nothing.
    @Test func aCardReadsTheConfigOnce() throws {
        var reads = 0
        var made: CardResolver?
        let surroundings = AgentHook.Surroundings(
            environment: ["__CFBundleIdentifier": "com.apple.Terminal"], hasGUISession: true, isInstalled: { _ in false },
            front: { _ in WhenFocused.Front(app: false, pane: false, idle: 0) },
            loadConfig: { _ in
                reads += 1
                return ConfigFile(config: Config(stack: .chain, stackMax: 5, history: 40), warnings: [])
            },
            resolver: { file, environment in
                let resolver = CardResolver(config: file.config, environment: try EnvironmentSettings(environment: environment))
                made = resolver
                return resolver
            })
        let card = try #require(try ShellHook.card(command: "make", status: 0, seconds: 30, in: surroundings))
        #expect(reads == 1)
        let settings = BackgroundSettings(try #require(made))
        let request = try BackgroundRequest.decode(BackgroundRequest(cards: [card], record: true, settings: settings).encoded())
        let read = { () -> BackgroundSettings in
            reads += 1
            return BackgroundSettings(stack: nil)
        }
        let shown = request.settings(orRead: read)
        #expect(shown.stack == StackSettings(max: 5))
        #expect(shown.history == 40)
        #expect(reads == 1)

        // Stacking off is said too, and needs no read.
        let off = try BackgroundRequest.decode(BackgroundRequest(
            cards: [card], record: true, settings: BackgroundSettings(CardResolver(config: Config(stack: .off)))).encoded())
        #expect(off.settings(orRead: read).stack == nil)
        #expect(reads == 1)

        // A request from a drip that predates `settings` reads them, once.
        let old = try BackgroundRequest.decode(Data(#"{"cards":[],"record":true,"history":7}"#.utf8))
        #expect(old.settings(orRead: read) == BackgroundSettings(stack: nil))
        #expect(reads == 2)
    }

    /// The second look at a waiting card a hook skipped reads the settings the hook's drip resolved,
    /// not the file.
    @Test func aSecondLookReadsTheSettingsTheHookRead() throws {
        var reads = 0
        let surroundings = AgentHook.Surroundings(
            environment: [:], hasGUISession: true, isInstalled: { _ in false },
            front: { _ in WhenFocused.Front(app: false, pane: false, idle: 0) },
            loadConfig: { _ in
                reads += 1
                return ConfigFile(config: Config(), warnings: [])
            },
            resolver: { file, _ in CardResolver(config: file.config) })
        let settings = BackgroundSettings(CardResolver(config: Config(whenFocused: .show, awayAfter: 30, debug: true)))
        let looked = surroundings.reading(settings)
        let file = looked.loadConfig([:])
        let resolver = try looked.resolver(file, [:])
        #expect(resolver.whenFocused == .show)
        #expect(resolver.awayAfter == 30)
        #expect(file.config.debug == true)
        #expect(file.warnings.isEmpty)
        #expect(reads == 0)
    }
    #endif
}
