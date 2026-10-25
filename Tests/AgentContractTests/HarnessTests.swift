#if os(macOS)
import CoreGraphics
import Foundation
import Testing

/// scripts/agent-contract/Contract.swift, the live agent check, run with stand-ins for npm and the
/// agents: what it does when it should run no agent, and one whole Codex session through drip's
/// own hooks.
struct HarnessTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The harness, built once for every test, inside the package's build folder.
    static let harness: Result<URL, Error> = Result {
        let directory = repo.appendingPathComponent(".build/agent-contract-tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("harness")
        let built = try execute(URL(fileURLWithPath: "/usr/bin/env"), ["swiftc", "-o", output.path,
                                repo.appendingPathComponent("scripts/agent-contract/Contract.swift").path])
        guard built == 0 else { throw BuildFailed(status: built) }
        return output
    }

    struct BuildFailed: Error { var status: Int32 }

    /// The drip this test run built.
    static let drip = (Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?.bundleURL.deletingLastPathComponent()
        ?? repo.appendingPathComponent(".build/debug")).appendingPathComponent("drip")

    static let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/run/current-system/sw/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @discardableResult
    static func execute(_ program: URL, _ arguments: [String], environment: [String: String]? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func output(_ program: String, _ arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// A cache of its own, and in it a folder for the stand-ins.
    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-contract-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("fake"), withIntermediateDirectories: true)
        return directory
    }

    static func script(_ text: String, at file: URL) throws {
        try ("#!/bin/sh\n" + text).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// An npm that notes it ran and exits with `status`.
    static func npm(in cache: URL, status: Int = 0) throws -> URL {
        let npm = cache.appendingPathComponent("fake/npm")
        try script("touch '\(cache.appendingPathComponent("fake/npm-ran").path)'\nexit \(status)\n", at: npm)
        return npm
    }

    /// The harness's run, with a tmux that notes it was asked to start anything.
    static func check(_ cache: URL, npm: URL, more: [String] = []) throws -> Int32 {
        let tmux = cache.appendingPathComponent("fake/tmux")
        try script("touch '\(cache.appendingPathComponent("fake/tmux-ran").path)'\n", at: tmux)
        return try execute(try harness.get(), ["run", "--repo", repo.path, "--cache", cache.path, "--tools",
                                               cache.appendingPathComponent("fake").path, "--tmux", tmux.path,
                                               "--npm", npm.path, "--drip", drip.path] + more)
    }

    static func last(_ cache: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: cache.appendingPathComponent("last.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func ran(_ cache: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: cache.appendingPathComponent("fake/\(name)-ran").path)
    }

    @Test func checkWithoutAGUISessionRunsNoAgent() throws {
        let cache = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: cache) }
        let status = try Self.check(cache, npm: try Self.npm(in: cache), more: ["--gui-session", "no"])
        #expect(status == 3)
        let last = try Self.last(cache)
        #expect(last["status"] as? String == "no-gui-session")
        #expect((last["exit"] as? NSNumber)?.int32Value == 3)
        #expect((last["reason"] as? String)?.contains("LaunchAgent") == true)
        #expect((last["agents"] as? [Any])?.isEmpty == true)
        // Nothing installed, no agent started, no run kept.
        #expect(!Self.ran(cache, "npm"))
        #expect(!Self.ran(cache, "tmux"))
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("runs").path))
    }

    @Test func aCheckThatFindsAnotherRunningLeavesIt() throws {
        let cache = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: cache) }
        let lastFile = cache.appendingPathComponent("last.json")
        try "{\"status\" : \"running\"}\n".write(to: lastFile, atomically: true, encoding: .utf8)
        // The running check's lock.
        let lock = open(cache.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)

        let status = try Self.check(cache, npm: try Self.npm(in: cache), more: ["--gui-session", "yes"])
        #expect(status == 4)
        // It installed nothing under the running check, and left its last.json alone.
        #expect(!Self.ran(cache, "npm"))
        #expect(try String(contentsOf: lastFile, encoding: .utf8) == "{\"status\" : \"running\"}\n")
    }

    @Test func aCheckThatCannotInstallTheAgentsSaysSo() throws {
        let cache = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: cache) }
        let status = try Self.check(cache, npm: try Self.npm(in: cache, status: 1), more: ["--gui-session", "yes"])
        #expect(status == 1)
        let last = try Self.last(cache)
        #expect(last["status"] as? String == "error")
        #expect((last["exit"] as? NSNumber)?.int32Value == 1)
        #expect((last["reason"] as? String)?.contains("npm install") == true)
        #expect(!Self.ran(cache, "tmux"))
    }

    /// A stand-in for Codex in its terminal: it runs drip's hook through a login shell, as Codex
    /// does, for each step of the session the check drives. Its first session asks nothing before
    /// it runs the command, which the check takes for a session that went its own way and tries once
    /// more; the second asks.
    static let codex = """
        case "$1" in --version) echo "codex-cli 0.0.0"; exit 0 ;; login) exit 0 ;; esac
        here=$(cd "$(dirname "$0")" && pwd)
        try=$(( $(cat "$here/tries" 2>/dev/null || echo 0) + 1 ))
        echo "$try" >"$here/tries"
        /bin/zsh -lc 'printf "%s" "$PATH"' >"$here/path-$try"
        hook() { printf '%s' "$1" | /bin/zsh -lc 'drip hook codex'; }
        base="\\"session_id\\":\\"session-$try\\",\\"cwd\\":\\"$PWD\\""
        input='{"command":"touch approved.txt"}'
        echo "? for shortcuts"
        read -r prompt
        hook "{\\"hook_event_name\\":\\"UserPromptSubmit\\",$base,\\"turn_id\\":\\"t1\\",\\"prompt\\":\\"go\\"}"
        if [ "$try" -gt 1 ]; then
            hook "{\\"hook_event_name\\":\\"PermissionRequest\\",$base,\\"turn_id\\":\\"t1\\",\\"tool_name\\":\\"Bash\\",\\"tool_input\\":$input}"
            read -r answer
            hook "{\\"hook_event_name\\":\\"PostToolUse\\",$base,\\"turn_id\\":\\"t1\\",\\"tool_name\\":\\"Bash\\",\\"tool_input\\":$input,\\"tool_use_id\\":\\"u1\\"}"
        fi
        hook "{\\"hook_event_name\\":\\"Stop\\",$base,\\"turn_id\\":\\"t1\\",\\"last_assistant_message\\":\\"done\\"}"
        read -r prompt
        hook "{\\"hook_event_name\\":\\"UserPromptSubmit\\",$base,\\"turn_id\\":\\"t2\\",\\"prompt\\":\\"ok\\"}"
        hook "{\\"hook_event_name\\":\\"Stop\\",$base,\\"turn_id\\":\\"t2\\",\\"last_assistant_message\\":\\"ok\\"}"
        exec sleep 600

        """

    @Test(.enabled(if: tmux != nil && CGSessionCopyCurrentDictionary() != nil, "needs tmux and a GUI session, where drip records cards"))
    func aCodexSessionThroughDripsHooks() throws {
        let cache = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: cache) }
        let fake = cache.appendingPathComponent("fake")
        try Self.script(Self.codex, at: fake.appendingPathComponent("codex"))
        let auth = fake.appendingPathComponent("auth.json")
        try "{}\n".write(to: auth, atomically: true, encoding: .utf8)

        let status = try Self.execute(try Self.harness.get(), [
            "run", "--repo", Self.repo.path, "--cache", cache.path, "--tools", fake.path, "--tmux", try #require(Self.tmux),
            "--npm", try Self.npm(in: cache).path, "--drip", Self.drip.path, "--node-bin", "/usr/bin", "--only", "codex",
            "--codex-auth", auth.path, "--gui-session", "yes", "--keep",
        ])
        let last = try Self.last(cache)
        let agents = try #require(last["agents"] as? [[String: Any]])
        let codex = try #require(agents.first)
        let failed = (codex["checks"] as? [[String: Any]] ?? []).filter { $0["ok"] as? Bool != true }
        #expect(status == 0, "\(failed)")
        #expect(last["status"] as? String == "passed")
        #expect((codex["attempts"] as? NSNumber)?.intValue == 2)

        // Each try keeps its own payloads, and the result names the try that counted.
        let run = URL(fileURLWithPath: try #require(last["run"] as? String))
        func kept(_ name: String) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: run.appendingPathComponent("payloads/\(name)").path).sorted()
        }
        #expect(try kept("codex-1") == ["001-UserPromptSubmit.json", "002-Stop.json", "003-UserPromptSubmit.json", "004-Stop.json"])
        #expect(try kept("codex-2") == [
            "001-UserPromptSubmit.json", "002-PermissionRequest.json", "003-PostToolUse.json", "004-Stop.json",
            "005-UserPromptSubmit.json", "006-Stop.json",
        ])
        #expect((codex["payloads"] as? String)?.hasSuffix("payloads/codex-2") == true)

        // A login shell, as Codex runs hooks in, finds the check's drip first.
        let world = run.appendingPathComponent("world/codex-2")
        let path = try String(contentsOf: fake.appendingPathComponent("path-2"), encoding: .utf8)
        #expect(path.split(separator: ":").first.map(String.init) == world.appendingPathComponent("bin").path)

        // drip is paused in the world, so every card went to its history and none to the notch.
        let state = world.appendingPathComponent("state").path
        let history = try Self.output(world.appendingPathComponent("bin/drip-real").path, ["history", "--json"], environment: [
            "HOME": world.appendingPathComponent("home").path, "XDG_STATE_HOME": state,
            "XDG_CONFIG_HOME": world.appendingPathComponent("config").path,
        ])
        let entries = history.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        #expect(entries.count == 4)
        #expect(entries.allSatisfy { $0["missed"] as? Bool == true })
    }
}
#endif
