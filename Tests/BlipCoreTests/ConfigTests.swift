import BlipCore
import XCTest

final class ConfigTests: XCTestCase {
    private let path = "/home/me/.config/blip/config.toml"

    func testTheSpecExample() throws {
        let file = try ConfigLoader.parse("""
            # every key optional
            seconds  = 4.5
            position = "bottom"          # bottom | center | top
            size     = "regular"         # compact | regular | large
            sound    = true              # false mutes every preset

            [preset.ok]                  # override a built-in preset, any subset of keys
            sound = "Hero"

            [preset.deploy]              # a custom preset: blip deploy "shipped"
            icon  = "paperplane.fill"
            color = "#a78bfa"
            sound = "Submarine"
            seconds = 6
            """, path: path)
        XCTAssertEqual(file.warnings, [])
        XCTAssertEqual(file.config, Config(
            seconds: 4.5, position: .bottom, size: .regular, sound: true,
            presets: [
                "ok": PresetOverride(sound: .named("Hero")),
                "deploy": PresetOverride(
                    icon: .symbol("paperplane.fill"), color: .rgb(red: 0xA7, green: 0x8B, blue: 0xFA),
                    sound: .named("Submarine"), seconds: 6),
            ]))
    }

    func testEmptyFile() throws {
        XCTAssertEqual(try ConfigLoader.parse("", path: path), ConfigFile(config: Config(), warnings: []))
    }

    func testOverridesMergeIntoBuiltInPresets() {
        let config = Config(presets: ["ok": PresetOverride(sound: .named("Hero")), "fail": PresetOverride(seconds: 9)])
        let presets = Dictionary(uniqueKeysWithValues: config.allPresets.map { ($0.name, $0) })
        XCTAssertEqual(presets["ok"], Preset(
            name: "ok", icon: .symbol("checkmark.circle.fill"), color: .system(.green), sound: .named("Hero")))
        XCTAssertEqual(presets["fail"]?.seconds, 9)
        XCTAssertEqual(presets["warn"], .warn)
        XCTAssertEqual(presets.count, 4)
    }

    func testCustomPresetsStartFromInfo() {
        let config = Config(presets: ["deploy": PresetOverride(color: .system(.purple))])
        let deploy = config.allPresets.first { $0.name == "deploy" }
        XCTAssertEqual(deploy, Preset(
            name: "deploy", icon: .symbol("info.circle.fill"), color: .system(.purple), sound: .named("Tink")))
    }

    func testPresetSoundForms() throws {
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
        XCTAssertEqual(file.config.presets["ok"]?.sound, Sound.none)
        XCTAssertEqual(file.config.presets["warn"]?.sound, Sound.none)
        XCTAssertNil(file.config.presets["fail"]?.sound)
        XCTAssertEqual(file.config.presets["info"]?.sound, .file("~/sounds/ding.aiff"))
    }

    func testIntegerSecondsAndIconNone() throws {
        let file = try ConfigLoader.parse("seconds = 3\n[preset.ok]\nicon = \"none\"", path: path)
        XCTAssertEqual(file.config.seconds, 3)
        XCTAssertEqual(file.config.presets["ok"]?.icon, Icon.none)
    }

    func testUnknownKeysAreWarnings() throws {
        let file = try ConfigLoader.parse("""
            seconds = 2
            colour = "red"
            [preset.ok]
            sond = "Hero"
            """, path: path)
        XCTAssertEqual(file.config.seconds, 2)
        XCTAssertEqual(file.warnings, [
            "\(path):2: unknown key 'colour'",
            "\(path):4: unknown key 'preset.ok.sond'",
        ])
    }

    func testWrongTypesNameTheKeyAndLine() {
        assertError("seconds = \"4\"", line: 1, key: "seconds", message: "expected a number, got a string")
        assertError("\nposition = 1", line: 2, key: "position", message: "expected a string, got an integer")
        assertError("size = true", line: 1, key: "size", message: "expected a string, got a boolean")
        assertError("sound = \"none\"", line: 1, key: "sound", message: "expected true or false, got a string")
        assertError("preset = 1", line: 1, key: "preset", message: "expected a table, got an integer")
        assertError("[preset]\nok = \"x\"", line: 2, key: "preset.ok", message: "expected a table, got a string")
        assertError("[preset.ok]\nicon = 1", line: 2, key: "preset.ok.icon", message: "expected a string, got an integer")
        assertError("[preset.ok]\n\nseconds = true", line: 3, key: "preset.ok.seconds",
                    message: "expected a number, got a boolean")
        assertError("[preset.ok]\nsound = 1", line: 2, key: "preset.ok.sound",
                    message: "expected a sound name, a path, \"none\" or false, got an integer")
    }

    func testInvalidValuesNameTheKeyAndLine() {
        assertError("seconds = 0.4", line: 1, key: "seconds", message: "must be between 0.5 and 60")
        assertError("seconds = 61", line: 1, key: "seconds", message: "must be between 0.5 and 60")
        assertError("position = \"left\"", line: 1, key: "position",
                    message: "expected bottom, center or top, got 'left'")
        assertError("size = \"huge\"", line: 1, key: "size", message: "expected compact, regular or large, got 'huge'")
        assertError("[preset.ok]\ncolor = \"teal\"", line: 2, key: "preset.ok.color",
                    message: "expected #rrggbb or one of green, orange, red, blue, purple, pink, yellow or gray, got 'teal'")
    }

    func testCustomPresetNames() throws {
        for name in ["deploy", "a", "ci-2", "x9"] {
            XCTAssertNotNil(try ConfigLoader.parse("[preset.\(name)]\nicon = \"star\"", path: path).config.presets[name])
        }
        for name in ["run", "Deploy", "2fa", "-x", "a_b"] {
            assertError("\n[preset.\(name)]", line: 2, key: "preset.\(name)", message: "a custom preset name must match")
        }
    }

    func testSyntaxErrorsNameTheLine() {
        assertError("seconds = 4.5\nposition = ", line: 2, key: nil, message: "expected a value")
        assertError("[preset.ok]\nsound = \"Hero\"\n[[preset]]", line: 3, key: nil,
                    message: "arrays of tables are not supported")
        assertError("seconds = 3\npreset.ok.icon = \"star\"", line: 2, key: nil,
                    message: "dotted keys are not supported")
    }

    func testPath() {
        XCTAssertEqual(ConfigLoader.path(environment: ["XDG_CONFIG_HOME": "/x", "HOME": "/home/me"]),
                       "/x/blip/config.toml")
        XCTAssertEqual(ConfigLoader.path(environment: ["HOME": "/home/me"]), "/home/me/.config/blip/config.toml")
        XCTAssertEqual(ConfigLoader.path(environment: ["XDG_CONFIG_HOME": "", "HOME": "/home/me"]),
                       "/home/me/.config/blip/config.toml")
        XCTAssertEqual(ConfigLoader.path(environment: ["XDG_CONFIG_HOME": "relative", "HOME": "/home/me"]),
                       "/home/me/.config/blip/config.toml")
    }

    func testLoadReadsTheFileAndAcceptsAMissingOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blip-config-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["XDG_CONFIG_HOME": directory.path]
        XCTAssertEqual(try ConfigLoader.load(environment: environment).config, Config())

        let blip = directory.appendingPathComponent("blip")
        try FileManager.default.createDirectory(at: blip, withIntermediateDirectories: true)
        try "size = \"large\"\n".write(to: blip.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try ConfigLoader.load(environment: environment).config, Config(size: .large))

        try Data([0xFF, 0xFE]).write(to: blip.appendingPathComponent("config.toml"))
        XCTAssertThrowsError(try ConfigLoader.load(environment: environment)) { error in
            XCTAssertEqual((error as? ConfigError)?.message, "the file is not UTF-8")
        }
    }

    func testErrorDescription() {
        let error = ConfigError(path: path, line: 3, key: "seconds", message: "expected a number, got a string")
        XCTAssertEqual(error.description, "\(path):3: seconds: expected a number, got a string")
        XCTAssertEqual(ConfigError(path: path, line: nil, key: nil, message: "cannot read the file").description,
                       "\(path): cannot read the file")
    }

    private func assertError(_ text: String, line: Int, key: String?, message: String, testLine: UInt = #line) {
        XCTAssertThrowsError(try ConfigLoader.parse(text, path: path), line: testLine) { error in
            guard let error = error as? ConfigError else { return XCTFail("\(error)", line: testLine) }
            XCTAssertEqual(error.path, path, line: testLine)
            XCTAssertEqual(error.line, line, "\(error)", line: testLine)
            XCTAssertEqual(error.key, key, "\(error)", line: testLine)
            XCTAssertTrue(error.message.hasPrefix(message), "\(error)", line: testLine)
        }
    }
}

final class PrecedenceTests: XCTestCase {
    func testEnvironmentSettings() throws {
        XCTAssertEqual(try EnvironmentSettings(environment: [:]), EnvironmentSettings())
        XCTAssertEqual(
            try EnvironmentSettings(environment: [
                "BLIP_SECONDS": "2", "BLIP_POSITION": "top", "BLIP_SIZE": "compact", "BLIP_SOUND": "none",
            ]),
            EnvironmentSettings(seconds: 2, position: .top, size: .compact, sound: Sound.none))
        XCTAssertEqual(try EnvironmentSettings(environment: ["BLIP_SECONDS": ""]), EnvironmentSettings())
        for (name, value) in [("BLIP_SECONDS", "abc"), ("BLIP_SECONDS", "99"), ("BLIP_POSITION", "left"),
                              ("BLIP_SIZE", "huge")] {
            XCTAssertThrowsError(try EnvironmentSettings(environment: [name: value])) { error in
                XCTAssertEqual((error as? UsageError)?.message.hasPrefix(name), true)
            }
        }
    }

    func testDefaultsWhenNothingIsSet() throws {
        let card = try CardResolver().resolve(kind: "ok", title: "t", flags: CardFlags())
        XCTAssertEqual(card.seconds, 4.5)
        XCTAssertEqual(card.position, .bottom)
        XCTAssertEqual(card.size, .regular)
        XCTAssertEqual(card.sound, .named("Glass"))
    }

    func testConfigBeatsDefaults() throws {
        let config = Config(seconds: 3, position: .center, size: .large)
        let card = try CardResolver(config: config).resolve(kind: "ok", title: "t", flags: CardFlags())
        XCTAssertEqual(card.seconds, 3)
        XCTAssertEqual(card.position, .center)
        XCTAssertEqual(card.size, .large)
    }

    func testPresetSecondsBeatGlobalConfigSeconds() throws {
        let config = Config(seconds: 3, presets: ["fail": PresetOverride(seconds: 8)])
        let resolver = CardResolver(config: config)
        XCTAssertEqual(try resolver.resolve(kind: "fail", title: "t", flags: CardFlags()).seconds, 8)
        XCTAssertEqual(try resolver.resolve(kind: "ok", title: "t", flags: CardFlags()).seconds, 3)
    }

    func testEnvironmentBeatsConfig() throws {
        let config = Config(seconds: 3, position: .center, size: .large, presets: ["ok": PresetOverride(seconds: 9)])
        let environment = EnvironmentSettings(seconds: 2, position: .top, size: .compact, sound: .named("Ping"))
        let card = try CardResolver(config: config, environment: environment)
            .resolve(kind: "ok", title: "t", flags: CardFlags())
        XCTAssertEqual(card.seconds, 2)
        XCTAssertEqual(card.position, .top)
        XCTAssertEqual(card.size, .compact)
        XCTAssertEqual(card.sound, .named("Ping"))
    }

    func testFlagsBeatEnvironment() throws {
        let environment = EnvironmentSettings(seconds: 2, position: .top, size: .compact, sound: Sound.none)
        let flags = CardFlags(seconds: 7, sound: .named("Hero"), position: .bottom, size: .regular)
        let card = try CardResolver(config: Config(seconds: 3), environment: environment)
            .resolve(kind: "ok", title: "t", flags: flags)
        XCTAssertEqual(card.seconds, 7)
        XCTAssertEqual(card.position, .bottom)
        XCTAssertEqual(card.size, .regular)
        XCTAssertEqual(card.sound, .named("Hero"))
    }

    func testConfigSoundFalseMutesEveryPreset() throws {
        let config = Config(sound: false, presets: ["ok": PresetOverride(sound: .named("Hero"))])
        let resolver = CardResolver(config: config)
        for kind in ["ok", "warn", "fail", "info"] {
            XCTAssertEqual(try resolver.resolve(kind: kind, title: "t", flags: CardFlags()).sound, Sound.none)
        }
        XCTAssertEqual(try resolver.resolve(kind: "ok", title: "t", flags: CardFlags(sound: .named("Pop"))).sound,
                       .named("Pop"))
        let unmuted = CardResolver(config: config, environment: EnvironmentSettings(sound: .named("Ping")))
        XCTAssertEqual(try unmuted.resolve(kind: "ok", title: "t", flags: CardFlags()).sound, .named("Ping"))
    }

    func testBlipSoundNoneMutes() throws {
        let resolver = CardResolver(environment: EnvironmentSettings(sound: Sound.none))
        XCTAssertEqual(try resolver.resolve(kind: "fail", title: "t", flags: CardFlags()).sound, Sound.none)
    }

    func testCustomPresetEndToEnd() throws {
        let file = try ConfigLoader.parse("""
            [preset.deploy]
            icon  = "paperplane.fill"
            color = "#a78bfa"
            sound = "Submarine"
            seconds = 6
            """, path: "config.toml")
        let resolver = CardResolver(config: file.config)
        let card = try resolver.resolve(kind: "deploy", title: "shipped", flags: CardFlags())
        XCTAssertEqual(card, Card(
            kind: "deploy", title: "shipped", icon: .symbol("paperplane.fill"),
            color: .rgb(red: 0xA7, green: 0x8B, blue: 0xFA), sound: .named("Submarine"), seconds: 6))
        // Without the config, deploy is just a title.
        XCTAssertEqual(try CardResolver().resolve(kind: "deploy", title: nil, flags: CardFlags()).title, "deploy")
    }

    func testOverriddenBuiltInPresetDrivesBlipRun() throws {
        let config = Config(presets: ["ok": PresetOverride(sound: .named("Hero")), "fail": PresetOverride(seconds: 10)])
        let resolver = CardResolver(config: config)
        XCTAssertEqual(try resolver.resolveRun(command: ["true"], status: 0, seconds: 1, flags: CardFlags()).sound,
                       .named("Hero"))
        XCTAssertEqual(try resolver.resolveRun(command: ["false"], status: 1, seconds: 1, flags: CardFlags()).seconds,
                       10)
    }
}
