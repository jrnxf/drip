#if !os(WASI) // Runs the built drip, which WebAssembly cannot.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import DripCore
import Foundation
import Testing

/// Each row of the exit code table, run as a script runs drip: the built drip, in a home, config,
/// state and queue of its own. `ExitStatus.table` is the table, and `drip --help`, docs/contract.md
/// and docs/usage.md show it word for word.
struct ExitCodeTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The drip this test run built. Not found through `Bundle.allBundles`: on Linux that walks
    /// CoreFoundation's bundle list without a lock and crashes while other tests run beside it.
    static let drip = repo.appendingPathComponent(".build/debug/drip")

    /// Whether this process runs in a logged-in macOS desktop, where drip shows cards.
    static var hasGUISession: Bool {
        #if canImport(CoreGraphics)
        return CGSessionCopyCurrentDictionary() != nil
        #else
        return false
        #endif
    }

    /// Cards on screen come only where nobody works at the Mac, as for scripts/mac-e2e.sh.
    static var mayShowCards: Bool {
        hasGUISession && ProcessInfo.processInfo.environment["DRIP_LIVE_CHECKS"] == "isolated"
    }

    /// One run of drip, and the code it should exit with.
    struct Case: CustomTestStringConvertible, Sendable {
        var code: Int32
        var what: String
        var arguments: [String]
        var input = ""
        var config: String?
        /// The state directory is a file, so nothing can be written there.
        var stateBroken = false
        var environment: [String: String] = [:]

        var testDescription: String { "\(code): \(what)" }
    }

    static let broken = "broken = ["

    /// Rows that come out the same with or without a GUI session, and show no card.
    static let anywhere: [Case] = [
        Case(code: 0, what: "the version", arguments: ["--version"]),
        Case(code: 0, what: "the help", arguments: ["--help"]),
        Case(code: 0, what: "an empty debug log emptied", arguments: ["debug", "--clear"]),
        Case(code: 0, what: "resume when not paused", arguments: ["resume"]),
        Case(code: 0, what: "an empty history as JSON", arguments: ["history", "--json"]),

        Case(code: 1, what: "drip debug --clear cannot write its state directory", arguments: ["debug", "--clear"],
             stateBroken: true),
        Case(code: 1, what: "drip pause cannot write its state directory", arguments: ["pause", "1m"],
             stateBroken: true),
        Case(code: 1, what: "drip dismiss cannot write its state directory", arguments: ["dismiss"],
             stateBroken: true),
        Case(code: 1, what: "drip hook gets a payload that is not JSON", arguments: ["hook", "claude"],
             input: "not json"),
        Case(code: 1, what: "drip watching has no terminal app to look at", arguments: ["watching"]),
        Case(code: 1, what: "drip watching --pane outside tmux", arguments: ["watching", "--pane", "%3"]),
        Case(code: 1, what: "drip watching with an invalid config", arguments: ["watching", "--app", "com.apple.Terminal"],
             config: broken),

        Case(code: 2, what: "an unknown option", arguments: ["--nope"]),
        Case(code: 2, what: "--yes with --open", arguments: ["ok", "t", "--yes", "Go", "--open", "https://example.com"]),
        Case(code: 2, what: "a DRIP_* variable drip cannot read", arguments: ["ok", "t"],
             environment: ["DRIP_SECONDS": "soon"]),
        Case(code: 2, what: "drip watching --pane that is no pane id", arguments: ["watching", "--pane", "bad"]),
        Case(code: 2, what: "drip watching with an extra argument", arguments: ["watching", "extra"]),
        Case(code: 2, what: "drip debug --clear with an extra argument", arguments: ["debug", "--clear", "extra"]),

        Case(code: 4, what: "an invalid config", arguments: ["ok", "t"], config: broken),
    ]

    /// Rows only a Mac without a GUI session gives, such as one reached over ssh, or Linux.
    static let withoutGUI: [Case] = [
        Case(code: 3, what: "a card without a GUI session", arguments: ["ok", "t"]),
        Case(code: 3, what: "a question without a GUI session", arguments: ["warn", "t", "--yes", "Go"]),
        Case(code: 0, what: "drip hook without a GUI session", arguments: ["hook", "claude"],
             input: #"{"hook_event_name":"Stop","session_id":"s1","cwd":"/home/user/api"}"#),
        Case(code: 1, what: "drip watching without a GUI session", arguments: ["watching", "--app", "com.apple.Terminal"]),
    ]

    /// Rows that show a real card and wait for it, unclicked.
    static let onScreen: [Case] = [
        Case(code: 5, what: "a question nobody answers",
             arguments: ["warn", "exit code check", "--yes", "Go", "--seconds", "0.5", "--sound", "none"]),
        Case(code: 0, what: "an --open card with --wait that nobody clicks",
             arguments: ["info", "exit code check", "--open", "https://example.com", "--wait", "--seconds", "0.5",
                         "--sound", "none"]),
    ]

    struct Outcome {
        var status: Int32
        var output: String
        var error: String
    }

    /// Runs drip with `arguments` in a home of its own, with `input` on its standard input.
    static func run(_ run: Case) throws -> Outcome {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("drip-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config.appendingPathComponent("drip"), withIntermediateDirectories: true)
        if let text = run.config {
            try text.write(to: config.appendingPathComponent("drip/config.toml"), atomically: false, encoding: .utf8)
        }
        let state = home.appendingPathComponent("state")
        if run.stateBroken {
            // A file where the directory should be: no one can create anything under it, root neither.
            try Data().write(to: state)
        }
        let input = home.appendingPathComponent("input")
        try Data(run.input.utf8).write(to: input)
        let output = home.appendingPathComponent("output")
        let error = home.appendingPathComponent("error")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: error.path, contents: nil)

        let process = Process()
        process.executableURL = drip
        process.arguments = run.arguments
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": home.path, "XDG_CONFIG_HOME": config.path, "XDG_STATE_HOME": state.path,
            "DRIP_QUEUE_DIR": home.appendingPathComponent("queue").path,
        ].merging(run.environment) { $1 }
        process.standardInput = try FileHandle(forReadingFrom: input)
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: error)
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(!process.isRunning, "drip \(run.arguments.joined(separator: " ")) did not end")
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return Outcome(
            status: process.terminationStatus,
            output: (try? String(contentsOf: output, encoding: .utf8)) ?? "",
            error: (try? String(contentsOf: error, encoding: .utf8)) ?? "")
    }

    static func expect(_ run: Case, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let outcome = try Self.run(run)
        #expect(outcome.status == run.code,
                "\(run.what): drip \(run.arguments.joined(separator: " ")) exits \(outcome.status), \(outcome.error)",
                sourceLocation: sourceLocation)
        // A failure always says what went wrong.
        if outcome.status != 0, run.code != 5 {
            #expect(!outcome.error.isEmpty, "\(run.what): it says nothing on stderr", sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: anywhere)
    func eachRowExitsWithItsCode(_ run: Case) throws {
        try Self.expect(run)
    }

    @Test(.enabled(if: !hasGUISession, "drip shows cards here"), arguments: withoutGUI)
    func withoutAGUISession(_ run: Case) throws {
        try Self.expect(run)
    }

    @Test(.enabled(if: mayShowCards, "shows cards only where DRIP_LIVE_CHECKS=isolated and a GUI session is"),
          arguments: onScreen)
    func onScreenRows(_ run: Case) throws {
        try Self.expect(run)
    }

    /// Every code in the table has a case above, and every case a row.
    @Test func everyRowHasACase() {
        let table = Set(ExitStatus.table.map(\.code))
        #expect(ExitStatus.table.map(\.code) == Array(0...5))
        #expect(Set((Self.anywhere + Self.withoutGUI + Self.onScreen).map(\.code)) == table)
    }

    /// `drip --help` ends with the table.
    @Test func helpEndsWithTheTable() throws {
        let outcome = try Self.run(Case(code: 0, what: "the help", arguments: ["--help"]))
        #expect(outcome.output.trimmingCharacters(in: .newlines).hasSuffix(ExitStatus.helpTable), "\(outcome.output)")
        #expect(!ExitStatus.helpTable.contains("`"))
    }

    /// The contract and the usage show the table as it is, and nowhere a code that is not in it.
    @Test(arguments: ["docs/contract.md", "docs/usage.md"])
    func theDocsShowTheTable(_ path: String) throws {
        let text = try String(contentsOf: Self.repo.appendingPathComponent(path), encoding: .utf8)
        #expect(text.contains(ExitStatus.markdownTable + "\n\n" + ExitStatus.tableNote), "\(path)")
        let rows = text.split(separator: "\n").filter { $0.hasPrefix("| Code |") }
        #expect(rows.count == 1, "\(path) has \(rows.count) exit code tables")
    }
}
#endif
