#if !os(WASI) // Reads files and runs the built drip, which WebAssembly cannot.
import DripCore
import Foundation
import Testing

/// A config file drip cannot fully use still leaves its cards showing: drip warns on stderr and
/// goes on with the default for each bad key. Exit 4 is kept for a command that checks the file.
struct BadConfigTests {
    let home: String

    init() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("drip-bad-config-\(UUID().uuidString)").path
    }

    var environment: [String: String] {
        ["XDG_STATE_HOME": "\(home)/state", "XDG_CONFIG_HOME": "\(home)/config", "HOME": home]
    }

    func writeConfig(_ data: Data) throws {
        try FileManager.default.createDirectory(atPath: "\(home)/config/drip", withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: "\(home)/config/drip/config.toml"))
    }

    @Test func aLenientLoadKeepsEveryDefaultForAFileItCannotUse() throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(ConfigLoader.loadLeniently(environment: environment) == ConfigFile(config: Config(), warnings: []))

        try writeConfig(Data("size = \"large\"\nseconds = \"five\"\n".utf8))
        let file = ConfigLoader.loadLeniently(environment: environment)
        #expect(file.config == Config(size: .large))
        #expect(file.problems.map(\.key) == ["seconds"])

        for (data, message) in [
            (Data([0xFF, 0xFE]), "the file is not UTF-8"),
            (Data(repeating: UInt8(ascii: "#"), count: ConfigLoader.sizeLimit + 1), "the file is larger than 1 MB"),
        ] {
            try writeConfig(data)
            let unusable = ConfigLoader.loadLeniently(environment: environment)
            #expect(unusable.config == Config(), "\(message)")
            #expect(unusable.problems.map(\.message) == [message])
            #expect(unusable.warnings.first?.hasSuffix("(drip ignores the file)") == true, "\(message)")
            // A command that checks the file still gets the error.
            #expect(throws: ConfigError.self) { try ConfigLoader.load(environment: environment) }
        }
    }

    /// The hook reads the config as a card command does: its card shows, with the good keys applied.
    @Test func aHookWithABadConfigStillMakesItsCard() throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        try writeConfig(Data("seconds = \"five\"\nsize = \"large\"\n[preset.ok]\ncolor = \"plaid\"\n".utf8))
        var warnings: [String] = []
        let surroundings = AgentHook.Surroundings(
            environment: environment, hasGUISession: true, isInstalled: { _ in false },
            front: { _ in WhenFocused.Front(app: false, pane: false, idle: 0) },
            resolver: { file, environment in
                warnings += file.warnings
                return CardResolver(config: file.config, environment: try EnvironmentSettings(environment: environment))
            })
        let stop = #"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"Stop","last_assistant_message":"Done"}"#
        let card = try AgentHook.card(agent: .claude, payload: stop, in: surroundings)
        #expect(card?.size == .large)
        #expect(warnings.count == 2)
        #expect(warnings.allSatisfy { $0.hasPrefix("invalid config: ") && $0.hasSuffix("(drip ignores this key)") })
    }

    /// The built drip warns about each bad key and answers as it would without them.
    @Test func dripWarnsAndGoesOn() throws {
        let outcome = try DripProcess.run(["watching", "--pane", "%3"], config: "seconds = \"five\"\nbroken = [\n")
        // Outside tmux drip cannot tell, with or without a GUI session: not exit 4.
        #expect(outcome.status == ExitStatus.cannotTell, "\(outcome.error)")
        #expect(outcome.error.contains("drip: warning: invalid config: "), "\(outcome.error)")
        #expect(outcome.error.contains("(drip ignores the file)"), "\(outcome.error)")
        #expect(outcome.error.contains("drip: cannot tell "), "\(outcome.error)")
    }
}
#endif
