#if os(macOS)
import Foundation
import Testing

/// scripts/agent-contract/Contract.swift without a GUI session, where drip records no card: it runs
/// no agent and says so in last.json, with an exit status of its own.
struct GUISessionTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The harness, built once for every test.
    static let harness: Result<URL, Error> = Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("harness")
        let built = try execute(URL(fileURLWithPath: "/usr/bin/env"), ["swiftc", "-o", output.path,
                                repo.appendingPathComponent("scripts/agent-contract/Contract.swift").path])
        guard built == 0 else { throw BuildFailed(status: built) }
        return output
    }

    struct BuildFailed: Error { var status: Int32 }

    static func execute(_ program: URL, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-contract-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func last(_ cache: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: cache.appendingPathComponent("last.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func checkWithoutAGUISessionRunsNoAgent() throws {
        let harness = try Self.harness.get()
        let cache = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: cache) }
        // Every agent session starts in tmux: this one notes that it was asked.
        let started = cache.appendingPathComponent("tmux-started")
        let tmux = cache.appendingPathComponent("tmux")
        try "#!/bin/sh\ntouch '\(started.path)'\n".write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux.path)

        let status = try Self.execute(harness, ["run", "--repo", Self.repo.path, "--cache", cache.path,
                                                "--tools", cache.appendingPathComponent("tools").path,
                                                "--tmux", tmux.path, "--gui-session", "no"])
        #expect(status == 3)
        let last = try Self.last(cache)
        #expect(last["status"] as? String == "no-gui-session")
        #expect((last["exit"] as? NSNumber)?.int32Value == 3)
        #expect((last["reason"] as? String)?.contains("LaunchAgent") == true)
        #expect((last["agents"] as? [Any])?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: started.path))
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("runs").path))
    }

    @Test func sessionCheckBeforeInstalling() throws {
        let harness = try Self.harness.get()
        let cache = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: cache) }

        let ready = try Self.execute(harness, ["session", "--repo", Self.repo.path, "--cache", cache.path, "--gui-session", "yes"])
        #expect(ready == 0)
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("last.json").path))

        let missing = try Self.execute(harness, ["session", "--repo", Self.repo.path, "--cache", cache.path, "--gui-session", "no"])
        #expect(missing == 3)
        #expect(try Self.last(cache)["status"] as? String == "no-gui-session")
    }
}
#endif
