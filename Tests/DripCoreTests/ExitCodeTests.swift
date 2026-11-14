#if !os(WASI) // Runs the built drip, which WebAssembly cannot.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import DripCore
import Foundation
import Testing

/// Each row of the exit code table, run as a script runs drip, through `DripProcess`.
/// `ExitStatus.table` is the table, and `drip --help`, docs/contract.md and docs/usage.md show it
/// word for word.
struct ExitCodeTests {
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
        Case(code: 0, what: "the help for a subcommand", arguments: ["help", "watching"]),
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
        // An invalid config is a warning: drip still answers, here that it cannot tell.
        Case(code: 1, what: "drip watching --pane outside tmux, with an invalid config", arguments: ["watching", "--pane", "%3"],
             config: broken),

        Case(code: 2, what: "an unknown option", arguments: ["--nope"]),
        Case(code: 2, what: "--yes with --open", arguments: ["ok", "t", "--yes", "Go", "--open", "https://example.com"]),
        Case(code: 2, what: "a DRIP_* variable drip cannot read", arguments: ["ok", "t"],
             environment: ["DRIP_SECONDS": "soon"]),
        Case(code: 2, what: "drip help with no such subcommand", arguments: ["help", "nope"]),
        Case(code: 2, what: "drip help with two subcommands", arguments: ["help", "watching", "extra"]),
        Case(code: 2, what: "drip watching --pane that is no pane id", arguments: ["watching", "--pane", "bad"]),
        Case(code: 2, what: "drip watching with an extra argument", arguments: ["watching", "extra"]),
        // Read before drip looks for a GUI session, so a host without one exits 2 too.
        Case(code: 2, what: "drip watching with a DRIP_* variable drip cannot read", arguments: ["watching"],
             environment: ["DRIP_AWAY_AFTER": "soon"]),
        // Read before drip looks for tmux, which it is not in here.
        Case(code: 2, what: "drip watching --pane with a DRIP_* variable drip cannot read",
             arguments: ["watching", "--pane", "%3"], environment: ["DRIP_SECONDS": "soon"]),
        Case(code: 2, what: "drip debug --clear with an extra argument", arguments: ["debug", "--clear", "extra"]),
        Case(code: 2, what: "drip doctor with a DRIP_* variable drip cannot read", arguments: ["doctor"],
             environment: ["DRIP_SECONDS": "soon"]),

        // An invalid config comes before what stops cards, so it is 4 with a GUI session or without.
        Case(code: 4, what: "drip doctor with an invalid config", arguments: ["doctor"], config: broken),
        Case(code: 4, what: "drip doctor --json with an invalid config", arguments: ["doctor", "--json"], config: broken),
    ]

    /// Rows only the macOS drip gives: elsewhere the background drip has no cards to show.
    static let macOnly: [Case] = [
        Case(code: 1, what: "the background drip gets no request", arguments: ["__background"]),
        Case(code: 1, what: "the background drip gets a request it cannot read", arguments: ["__background"],
             input: "not json"),
    ]

    /// Rows only a Mac without a GUI session gives, such as one reached over ssh, or Linux.
    static let withoutGUI: [Case] = [
        Case(code: 3, what: "a card without a GUI session", arguments: ["ok", "t"]),
        Case(code: 3, what: "a question without a GUI session", arguments: ["warn", "t", "--yes", "Go"]),
        Case(code: 3, what: "a card with an invalid config, without a GUI session", arguments: ["ok", "t"],
             config: broken),
        Case(code: 0, what: "drip hook without a GUI session", arguments: ["hook", "claude"],
             input: #"{"hook_event_name":"Stop","session_id":"s1","cwd":"/home/user/api"}"#),
        Case(code: 1, what: "drip watching without a GUI session", arguments: ["watching", "--app", "com.apple.Terminal"]),
        // On Linux drip shows no cards at all, so no GUI session stops nothing there.
        Case(code: showsCards ? 1 : 0, what: "drip doctor without a GUI session", arguments: ["doctor"]),
    ]

    #if canImport(AppKit)
    static let showsCards = true
    #else
    static let showsCards = false
    #endif

    /// Rows that show a real card and wait for it, unclicked.
    static let onScreen: [Case] = [
        Case(code: 5, what: "a question nobody answers",
             arguments: ["warn", "exit code check", "--yes", "Go", "--seconds", "0.5", "--sound", "none"]),
        Case(code: 0, what: "an --open card with --wait that nobody clicks",
             arguments: ["info", "exit code check", "--open", "https://example.com", "--wait", "--seconds", "0.5",
                         "--sound", "none"]),
        Case(code: 0, what: "a card with an invalid config",
             arguments: ["info", "exit code check", "--seconds", "0.5", "--sound", "none"], config: broken),
        Case(code: 0, what: "drip hook with an invalid config", arguments: ["hook", "claude"],
             input: #"{"hook_event_name":"Stop","session_id":"s1","cwd":"/home/user/api"}"#, config: broken,
             environment: ["DRIP_SECONDS": "0.5", "DRIP_SOUND": "none"]),
    ]

    /// Why a list of rows does not run on this host, and which rows those are, for the test output.
    static func skipped(_ cases: [Case], because reason: String) -> Comment {
        Comment(rawValue: "\(reason), so these rows do not run here: "
            + cases.map(\.testDescription).joined(separator: "; "))
    }

    static func expect(_ run: Case, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let outcome = try DripProcess.run(
            run.arguments, input: Data(run.input.utf8), config: run.config, stateBroken: run.stateBroken,
            environment: run.environment, sourceLocation: sourceLocation)
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

    #if canImport(AppKit)
    @Test(arguments: macOnly)
    func macRows(_ run: Case) throws {
        try Self.expect(run)
    }
    #endif

    @Test(.enabled(if: !hasGUISession, skipped(withoutGUI, because: "this host has a GUI session, which shows cards")),
          arguments: withoutGUI)
    func withoutAGUISession(_ run: Case) throws {
        try Self.expect(run)
    }

    @Test(.enabled(if: mayShowCards, skipped(onScreen, because: "cards show only with a GUI session and DRIP_LIVE_CHECKS=isolated")),
          arguments: onScreen)
    func onScreenRows(_ run: Case) throws {
        try Self.expect(run)
    }

    /// The lists above name a case for each code in the table. Which of them run depends on the host:
    /// the tests above say which they skip.
    @Test func everyCodeHasACaseListed() {
        let table = Set(ExitStatus.table.map(\.code))
        #expect(ExitStatus.table.map(\.code) == Array(0...5))
        #expect(Set((Self.anywhere + Self.macOnly + Self.withoutGUI + Self.onScreen).map(\.code)) == table)
    }

    // MARK: - Exit 5, without a screen

    static func card(_ preset: Preset, _ title: String, _ action: CardAction) -> Card {
        var card = Card(preset: preset, title: title)
        card.action = action
        return card
    }

    static let question = card(.warn, "Deploy?", CardAction(label: "Deploy", open: nil))
    static let link = card(.info, "CI", CardAction(label: "View run", open: "https://example.com"))
    static let plain = Card(preset: .ok, title: "done")

    /// Only a question goes unanswered: a card with an `--open` button asks nothing.
    @Test func onlyAnUnclickedQuestionGoesUnanswered() {
        #expect(Self.question.goesUnanswered(clicked: false))
        #expect(!Self.question.goesUnanswered(clicked: true))
        #expect(!Self.link.goesUnanswered(clicked: false))
        #expect(!Self.link.goesUnanswered(clicked: true))
        #expect(!Self.plain.goesUnanswered(clicked: false))
    }

    /// A drip that waited on a question answered yes and a link nobody clicked exits 0, as the
    /// presenters work it out: each card that goes marks the wait missed only if it goes unanswered.
    @Test(arguments: [
        ([(question, true), (link, false)], ExitStatus.shown),
        ([(link, false)], ExitStatus.shown),
        ([(link, true), (plain, false)], ExitStatus.shown),
        ([(question, false), (link, true)], ExitStatus.notClicked),
        ([(question, false)], ExitStatus.notClicked),
    ] as [([(Card, Bool)], Int32)])
    func aWaitExitsFiveOnlyForAQuestion(_ cards: [(Card, Bool)], _ code: Int32) {
        let missed = cards.contains { card, clicked in card.goesUnanswered(clicked: clicked) }
        #expect(ExitStatus.answered(missed: missed, declined: false) == code, "\(cards.map(\.0.title))")
    }

    // MARK: - The help and the docs

    /// `drip --help` ends with the table, wrapped to the width the rest of the help is.
    @Test(arguments: [nil, 60, 120] as [Int?])
    func helpEndsWithTheTable(columns: Int?) throws {
        let outcome = try DripProcess.run(["--help"], environment: columns.map { ["COLUMNS": "\($0)"] } ?? [:])
        let table = ExitStatus.helpTable(width: columns ?? 80)
        #expect(outcome.output.trimmingCharacters(in: .newlines).hasSuffix(table), "\(outcome.output)")
    }

    /// Each line of the table fits the width, and a meaning hangs under its first line.
    @Test(arguments: [40, 60, 80, 120])
    func helpTableWraps(width: Int) {
        let lines = ExitStatus.helpTable(width: width).split(separator: "\n")
        #expect(lines.first == "EXIT CODES:")
        #expect(!lines.contains { $0.contains("`") })
        for line in lines {
            #expect(line.count < width, "\(width): \(line)")
        }
        for row in ExitStatus.table {
            let wrapped = ExitStatus.wrap(row.meaning, first: "  \(row.code)  ", rest: "     ", width: width)
                .split(separator: "\n")
            #expect(wrapped.dropFirst().allSatisfy { $0.hasPrefix("     ") && $0.dropFirst(5).first != " " },
                    "\(width): row \(row.code)")
        }
        #expect(lines.dropFirst().allSatisfy { $0.hasPrefix("  ") }, "\(width)")
        // Every meaning is there, word for word, once the wrapping is taken out.
        let text = lines.joined(separator: " ").split(separator: " ").joined(separator: " ")
        for row in ExitStatus.table {
            #expect(text.contains(row.meaning.replacingOccurrences(of: "`", with: "")), "\(width): row \(row.code)")
        }
    }

    /// The contract and the usage show the table as it is, and no other exit code table.
    @Test(arguments: ["docs/contract.md", "docs/usage.md"])
    func theDocsShowTheTable(_ path: String) throws {
        let text = try String(contentsOf: DripProcess.repo.appendingPathComponent(path), encoding: .utf8)
        #expect(text.contains(ExitStatus.markdownTable), "\(path)")
        let rows = text.split(separator: "\n").filter { $0.hasPrefix("| Code |") }
        #expect(rows.count == 1, "\(path) has \(rows.count) exit code tables")
    }
}
#endif
