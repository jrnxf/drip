#if !os(WASI) // Runs the built drip, which WebAssembly cannot.
import Foundation
import Testing

/// What `drip hook` exits with when the hook goes wrong, run as the agent runs it. Claude Code reads
/// a hook's exit 2 as "block": on a `PermissionRequest` that turns drip's card into a denied
/// permission. `report` returns 2 for a usage error, so only the mapping at the end of `hook(_:)`
/// in the drip target keeps a bad payload from blocking the agent's tool call, and the parser's
/// tests in CommandTests never reach it.
struct HookExitStatusTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The drip this test run built. Not found through `Bundle.allBundles`: on Linux that walks
    /// CoreFoundation's bundle list without a lock and crashes while other tests run beside it.
    static let drip = repo.appendingPathComponent(".build/debug/drip")

    static let permission = """
        {"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash",\
        "tool_input":{"command":"ls"},"cwd":"/home/user/api"}
        """

    /// Gemini asks for a permission with a `Notification`: it has no `PermissionRequest`.
    static let geminiPermission = """
        {"hook_event_name":"Notification","session_id":"g1","notification_type":"ToolPermission",\
        "message":"Allow run_shell_command: ls?","details":{"tool_name":"run_shell_command"},"cwd":"/home/user/api"}
        """

    struct Outcome {
        var status: Int32
        var error: String
    }

    /// Runs `drip hook <agent>` with `payload` on its standard input, in a home of its own.
    private func hook(
        _ agent: String, payload: Data, environment extra: [String: String] = [:], config: String? = nil
    ) throws -> Outcome {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("drip-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        if let config {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("config/drip"), withIntermediateDirectories: true)
            try config.write(to: home.appendingPathComponent("config/drip/config.toml"), atomically: false, encoding: .utf8)
        }
        // A file, not a pipe: a payload past the limit is not read to its end, and a write to the
        // pipe of a process that has stopped reading would fail.
        let input = home.appendingPathComponent("payload")
        try payload.write(to: input)
        let error = home.appendingPathComponent("error")
        FileManager.default.createFile(atPath: error.path, contents: nil)

        let process = Process()
        process.executableURL = Self.drip
        process.arguments = ["hook", agent]
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent("config").path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "DRIP_QUEUE_DIR": home.appendingPathComponent("queue").path,
        ].merging(extra) { $1 }
        process.standardInput = try FileHandle(forReadingFrom: input)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: error)
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(!process.isRunning, "drip hook \(agent) did not end")
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return Outcome(
            status: process.terminationStatus,
            error: (try? String(contentsOf: error, encoding: .utf8)) ?? "")
    }

    private func expectNeverBlocks(
        _ outcome: Outcome, _ what: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(outcome.status == 0 || outcome.status == 1, "\(what): exit \(outcome.status), \(outcome.error)",
                sourceLocation: sourceLocation)
    }

    @Test(arguments: ["claude", "codex", "gemini"])
    func aBadPayloadFailsTheHookWithOneNotTwo(agent: String) throws {
        let bad: [(String, Data)] = [
            ("an empty payload", Data()),
            ("a payload that is not JSON", Data("not json".utf8)),
            ("a payload that is not an object", Data("[1,2]".utf8)),
            ("an event drip does not know", Data(#"{"hook_event_name":"Nope","session_id":"s"}"#.utf8)),
            // One byte past the 4 MB drip reads.
            ("a payload past 4 MB", Data(repeating: UInt8(ascii: " "), count: 4 * 1024 * 1024 + 1)),
        ]
        for (what, payload) in bad {
            let outcome = try hook(agent, payload: payload)
            // The mistake is the hook's to report: it exits 1 and says why, and never 0 (shown).
            #expect(outcome.status == 1, "\(agent), \(what): exit \(outcome.status), \(outcome.error)")
            #expect(!outcome.error.isEmpty, "\(agent), \(what): it says nothing")
        }
    }

    @Test(arguments: ["claude", "codex", "gemini"])
    func aBrokenConfigNeverBlocksAPermission(agent: String) throws {
        let permission = agent == "gemini" ? Self.geminiPermission : Self.permission
        let outcome = try hook(agent, payload: Data(permission.utf8), config: "broken = [")
        expectNeverBlocks(outcome, "\(agent), a broken config.toml")
    }

    @Test(arguments: ["claude", "codex", "gemini"])
    func aSilencedHookNeverBlocks(agent: String) throws {
        for payload in [Self.permission, "", "not json"] {
            let outcome = try hook(agent, payload: Data(payload.utf8), environment: ["DRIP_HOOK": "off"])
            expectNeverBlocks(outcome, "\(agent), DRIP_HOOK=off, payload \(payload.prefix(12))")
        }
        // A DRIP_HOOK drip does not know is a mistake too, and no more a reason to block.
        let unknown = try hook(agent, payload: Data(Self.permission.utf8), environment: ["DRIP_HOOK": "sometimes"])
        expectNeverBlocks(unknown, "\(agent), DRIP_HOOK=sometimes")
    }
}
#endif
