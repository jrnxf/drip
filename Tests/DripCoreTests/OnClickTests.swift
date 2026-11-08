import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import Testing

/// `--on-click`: the command a click on a card runs, and the payload it reads on stdin.
struct OnClickTests {
    func make(_ kind: String, _ title: String) -> Card {
        Card(preset: Preset.builtIn.first { $0.name == kind }!, title: title)
    }

    @Test func thePayloadIsSmallVersionedJSON() {
        var card = Card.staying(title: "api is done")
        card.id = "claude:s1@devbox"
        card.activate = "com.mitchellh.ghostty"
        let onClick = OnClick(command: "my-focus", machine: "devbox", environment: ["HERDR_PANE_ID": "w1:p2"])
        #expect(onClick.payload(for: card) == #"""
            {"app":"com.mitchellh.ghostty","env":{"HERDR_PANE_ID":"w1:p2"},"id":"claude:s1@devbox","kind":"\#(card.kind)","machine":"devbox","title":"api is done","v":1}

            """#)
        // A card of this Mac, with no id and no app: only what it has.
        let plain = make("ok", "tests passed")
        #expect(OnClick(command: "x").payload(for: plain) == #"{"env":{},"kind":"ok","title":"tests passed","v":1}"# + "\n")
    }

    @Test func thePayloadNeverHoldsTheRestOfTheCard() throws {
        var card = make("fail", String(repeating: "t", count: 2000))
        card.detail = "secret detail"
        card.action = CardAction(label: "Open", open: "/home/user/report.html")
        let payload = OnClick(command: "x").payload(for: card)
        let object = try JSONValue(parsing: payload)
        #expect(Set(try #require(object.members).map(\.key)) == ["v", "kind", "title", "env"])
        #expect(object["title"]?.string?.count == OnClick.titleLimit)
        #expect(!payload.contains("secret") && !payload.contains("report.html"))
        #if !os(WASI)
        #expect(payload.utf8.count < TimedCommand.inputLimit)
        #endif
    }

    @Test func dripForwardEnvNamesTheVariablesPassedOn() {
        let environment = [
            "DRIP_FORWARD_ENV": "HERDR_PANE_ID\tWEZTERM_PANE  EMPTY UNSET 1BAD BAD-NAME $(id) CONTROL LONG",
            "HERDR_PANE_ID": "w1:p2", "WEZTERM_PANE": "7", "EMPTY": "", "1BAD": "x", "BAD-NAME": "x",
            "CONTROL": "a\nb", "LONG": String(repeating: "x", count: ForwardedEnvironment.valueLimit + 1),
        ]
        #expect(ForwardedEnvironment.read(environment) == ["HERDR_PANE_ID": "w1:p2", "WEZTERM_PANE": "7"])
        #expect(ForwardedEnvironment.read(["HOME": "/home/user"]) == [:])
        // At most countLimit names.
        let many = (0..<40).map { "V\($0)" }
        let lots = Dictionary(uniqueKeysWithValues: many.map { ($0, "x") })
            .merging(["DRIP_FORWARD_ENV": many.joined(separator: " ")]) { $1 }
        #expect(ForwardedEnvironment.read(lots).count == ForwardedEnvironment.countLimit)
        #expect(!ForwardedEnvironment.isName(String(repeating: "A", count: ForwardedEnvironment.nameLimit + 1)))
    }

    @Test func aCardOfThisMacTakesTheFlagAndItsShellsForwardedVariables() throws {
        let environment = try EnvironmentSettings(environment: [
            "DRIP_FORWARD_ENV": "WEZTERM_PANE", "WEZTERM_PANE": "7", "HOME": "/home/user",
        ])
        let resolver = CardResolver(environment: environment)
        let card = try resolver.resolve(kind: "ok", title: "built", flags: CardFlags(onClick: "my-focus"))
        #expect(card.onClick == OnClick(command: "my-focus", environment: ["WEZTERM_PANE": "7"]))
        #expect(card.isClickable && card.opensOnClick)
        let none = try resolver.resolve(kind: "ok", title: "built", flags: CardFlags())
        #expect(none.onClick == nil)
    }

    @Test(arguments: [
        ["ok", "hi", "--on-click", "my-focus"],
        ["run", "--on-click", "my-focus", "make"],
        ["hook", "claude", "--on-click", "my-focus"],
    ])
    func everyCardCommandTakesOnClick(_ arguments: [String]) throws {
        let flags: CardFlags
        switch CommandLineParser.parse(arguments) {
        case let .invocation(.show(command)): flags = command.options.flags
        case let .invocation(.run(command)): flags = command.options.flags
        case let .invocation(.hook(command)): flags = command.options.flags
        default: Issue.record("\(arguments)"); return
        }
        #expect(flags.onClick == "my-focus")
    }

    @Test func anEmptyOnClickIsAUsageError() {
        for arguments in [["hi", "--on-click", ""], ["run", "--on-click", "", "make"], ["follow", "devbox", "--on-click", ""]] {
            guard case let .exit(status, _) = CommandLineParser.parse(arguments) else {
                Issue.record("\(arguments)"); continue
            }
            #expect(status == ExitStatus.usage, "\(arguments)")
        }
    }

    #if !os(WASI) // Files, and processes, which WebAssembly cannot start.
    @Test func historyNeverKeepsOrReplaysAClickCommand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drip-onclick-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let history = CardHistory(path: "\(directory)/history.jsonl")
        var card = make("ok", "built")
        card.onClick = OnClick(command: "my-focus")
        try history.record([card], missed: true)
        let text = try String(contentsOfFile: history.path, encoding: .utf8)
        #expect(!text.contains("my-focus"))
        #expect(history.entries().first?.card.onClick == nil)
        #expect(HistoryListing.replay(HistoryEntry(time: Date(), missed: true, card: card)).onClick == nil)
    }

    @Test func theCommandReadsThePayloadOnStdin() {
        let card = make("ok", "built")
        let onClick = OnClick(command: "cat")
        #expect(TimedCommand.run(["/bin/sh", "-c", onClick.command], input: onClick.payload(for: card), timeout: 5)
            == .success(onClick.payload(for: card)))
    }
    #endif
}
