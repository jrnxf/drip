#if !os(WASI)
import DripCore
import Foundation
import Testing

/// A permission card with Allow and Deny, with `approve` on: a click is the agent's answer, and
/// anything else leaves the answer to the terminal.
struct ApprovalTests {
    let state: String
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("drip-approve-\(UUID().uuidString)").path
    }

    static let claude = #"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#
    static let codex = #"{"session_id":"s1","turn_id":"t1","cwd":"/home/user/api","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#

    /// What `drip hook` reads around an event on this Mac, with the terminal where `front` says.
    func local(
        _ environment: [String: String] = ["DRIP_APPROVE": "1"],
        front: WhenFocused.Front = WhenFocused.Front(app: false, pane: false, idle: 0), away: Bool = false
    ) -> AgentHook.Surroundings {
        AgentHook.Surroundings(
            environment: [
                "XDG_STATE_HOME": state, "XDG_CONFIG_HOME": "\(state)/config", "HOME": state,
                "__CFBundleIdentifier": "com.apple.Terminal",
            ]
                .merging(environment) { $1 },
            hasGUISession: true, isInstalled: { _ in false }, front: { _ in front }, away: { away },
            resolver: { _, environment in CardResolver(config: Config(), environment: try EnvironmentSettings(environment: environment)) },
            now: { now })
    }

    @Test func theAnswerIsWhatTheAgentReads() throws {
        #expect(AgentHook.Approval.allow.output == """
            {
              "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                  "behavior": "allow"
                }
              }
            }

            """)
        let deny = try JSONValue(parsing: AgentHook.Approval.deny.output)
        #expect(deny == .object([
            JSONMember("hookSpecificOutput", .object([
                JSONMember("hookEventName", .string("PermissionRequest")),
                JSONMember("decision", .object([
                    JSONMember("behavior", .string("deny")), JSONMember("message", .string("Denied from the drip card.")),
                ])),
            ])),
        ]))
    }

    @Test func onlyAPressAnswers() {
        #expect(AgentHook.Approval(pressed: .yes, status: ExitStatus.shown) == .allow)
        #expect(AgentHook.Approval(pressed: .no, status: ExitStatus.declined) == .deny)
        // Nothing clicked, a click on the card itself, the card taken away: the terminal asks.
        #expect(AgentHook.Approval(pressed: nil, status: ExitStatus.notClicked) == nil)
        #expect(AgentHook.Approval(pressed: nil, status: ExitStatus.usage) == nil)
        #expect(AgentHook.Approval(pressed: nil, status: ExitStatus.noGUISession) == nil)
        // A drip that showed nothing exits 0 too: without a press, that is no answer.
        #expect(AgentHook.Approval(pressed: nil, status: ExitStatus.shown) == nil)
        // A press the exit status does not bear out answers nothing either.
        #expect(AgentHook.Approval(pressed: .yes, status: ExitStatus.notClicked) == nil)
        #expect(AgentHook.Approval(pressed: .yes, status: ExitStatus.declined) == nil)
        #expect(AgentHook.Approval(pressed: .no, status: ExitStatus.shown) == nil)
    }

    /// A stack drops its own permission card before it ever shows when a newer card of the session
    /// replaced it, or a dismiss came for it: the card is handed back to be noted as missed, nothing
    /// was pressed, and the terminal asks.
    @Test func aPermissionCardDroppedBeforeItShowsGivesNoAnswer() throws {
        let asking = AgentHook.asking(try #require(try AgentHook.card(agent: .claude, payload: Self.claude, in: local([:]))))
        let settings = StackSettings(mode: .chain, max: 3)

        let replaced = CardStack(settings: settings, cards: [asking])
        guard case .skipOwn? = replaced.nextRelease(adoptable: [], isReplaced: { $0.id == asking.id }) else {
            Issue.record("a replaced permission card is skipped, not shown")
            return
        }
        let skipped = replaced.dropWaiting(at: 0)
        #expect(skipped?.action != nil)
        #expect(replaced.entries.isEmpty)
        #expect(replaced.waiting.isEmpty)

        let dismissed = CardStack(settings: settings, cards: [asking])
        #expect(dismissed.dropWaiting(where: { $0.id == asking.id }).map(\.action) == [asking.action])
        #expect(dismissed.entries.isEmpty)
        #expect(dismissed.dropWaiting(where: { _ in true }).isEmpty)

        #expect(AgentHook.Approval(pressed: nil, status: ExitStatus.shown) == nil)
        #expect(AgentHook.Approval(pressed: nil, status: ExitStatus.notClicked) == nil)
    }

    @Test func theSettingIsOffUnlessTurnedOn() throws {
        #expect(!CardResolver().approve)
        let config = try ConfigLoader.parse("approve = true", path: "config.toml").config
        #expect(config == Config(approve: true))
        #expect(CardResolver(config: config).approve)
        let off = try EnvironmentSettings(environment: ["DRIP_APPROVE": "0"])
        #expect(off == EnvironmentSettings(approve: false))
        #expect(!CardResolver(config: config, environment: off).approve)
        #expect(CardResolver(environment: try EnvironmentSettings(environment: ["DRIP_APPROVE": "yes"])).approve)
        #expect(try EnvironmentSettings(environment: ["DRIP_APPROVE": ""]) == EnvironmentSettings())
        let error = #expect(throws: UsageError.self) { try EnvironmentSettings(environment: ["DRIP_APPROVE": "maybe"]) }
        #expect(error?.message == "DRIP_APPROVE must be 1 or 0, not 'maybe'")
        #expect(throws: ConfigError.self) { try ConfigLoader.parse("approve = \"yes\"", path: "config.toml") }
    }

    @Test(arguments: [AgentHook.Agent.claude, .codex])
    func aPermissionCardAsksWithApproveOn(_ agent: AgentHook.Agent) throws {
        let payload = agent == .claude ? Self.claude : Self.codex
        let card = try #require(try AgentHook.card(agent: agent, payload: payload, in: local()))
        #expect(card.action == CardAction(label: "Allow", open: nil, decline: "Deny"))
        #expect(card.waitsForAnswer)
        #expect(card.waitLimit == Defaults.approveWait)
        #expect(Defaults.approveWait < 600)
        #expect(card.id == "\(agent.rawValue):s1")

        // Off, as by default: the card only tells you, as before.
        let plain = try #require(try AgentHook.card(agent: agent, payload: payload, in: local([:])))
        #expect(plain.action == nil)
        #expect(plain.waitLimit == Defaults.waitLimit)
        var same = card
        same.action = nil
        same.waitLimit = Defaults.waitLimit
        #expect(same == plain)
    }

    @Test func onlyAPermissionRequestAsks() throws {
        let notice = #"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#
        let question = #"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"Notification","message":"Claude has a question","notification_type":"elicitation_dialog"}"#
        let stop = #"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"Stop","last_assistant_message":"Done."}"#
        for payload in [notice, question, stop] {
            let card = try #require(try AgentHook.card(agent: .claude, payload: payload, in: local()))
            #expect(card.action == nil, "\(payload)")
        }
        // Gemini CLI asks for nothing drip can answer.
        let gemini = #"{"session_id":"s1","cwd":"/home/user/api","hook_event_name":"Notification","notification_type":"ToolPermission","message":"Gemini wants to run ls"}"#
        #expect(try AgentHook.card(agent: .gemini, payload: gemini, in: local())?.action == nil)
        // No session to take the card away by.
        let sessionless = #"{"cwd":"/home/user/api","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#
        #expect(try #require(try AgentHook.card(agent: .claude, payload: sessionless, in: local())).action == nil)
    }

    @Test func aRemoteCardOnlyTells() throws {
        let event = RemoteEvent(
            time: now.timeIntervalSince1970, agent: .claude, machine: "devbox", environment: [:], payload: Self.claude)
        let card = try #require(try AgentHook.card(
            agent: .claude, payload: Self.claude,
            in: event.surroundings(local(), activate: nil, onClick: nil, stale: false)))
        #expect(card.id == "claude:s1@devbox")
        #expect(card.action == nil)
        #expect(card.waitLimit == Defaults.waitLimit)
    }

    @Test func aCardHeldWhileYouAreAwayOnlyTells() throws {
        let card = try #require(try AgentHook.card(agent: .claude, payload: Self.claude, in: local(away: true)))
        #expect(card.action == nil)
    }

    /// Codex asks in its terminal only once the hook returns: with you watching it, the card only
    /// tells you, and the hook returns at once. Claude Code asks at once, so its card asks too.
    @Test func codexAsksOnTheCardOnlyWhileYouAreNotWatching() throws {
        let watching = WhenFocused.Front(app: true, pane: true, idle: 0)
        #expect(try AgentHook.card(agent: .codex, payload: Self.codex, in: local(front: watching))?.action == nil)
        #expect(try AgentHook.card(agent: .claude, payload: Self.claude, in: local(front: watching))?.action != nil)
        // when_focused = "show" looks at nothing for the card, but the answer still does.
        let show = ["DRIP_APPROVE": "1", "DRIP_WHEN_FOCUSED": "show"]
        #expect(try AgentHook.card(agent: .codex, payload: Self.codex, in: local(show, front: watching))?.action == nil)
        #expect(try AgentHook.card(agent: .codex, payload: Self.codex, in: local(show))?.action != nil)
        // Another pane, another app, or nobody at the screen: not watching.
        for front in [
            WhenFocused.Front(app: true, pane: false, idle: 0), WhenFocused.Front(app: false, pane: true, idle: 0),
            WhenFocused.Front(app: true, pane: true, idle: WhenFocused.defaultAwayAfter),
        ] {
            #expect(try AgentHook.card(agent: .codex, payload: Self.codex, in: local(front: front))?.action != nil, "\(front)")
        }
    }

    @Test func goingToTheTerminalCountsOnlyAsItComesToTheFront() {
        func arrivals(_ fronts: [WhenFocused.Front]) -> [Bool] {
            var arrival = TerminalArrival()
            return fronts.map { arrival.arrived($0) }
        }
        let here = WhenFocused.Front(app: true, pane: true)
        // In front at the first look: you may have left it there, and come back to the card.
        #expect(arrivals([here, here, WhenFocused.Front(app: false, pane: true), here]) == [false, false, false, true])
        // Another pane of the same terminal is not the agent's.
        #expect(arrivals([WhenFocused.Front(app: false), WhenFocused.Front(app: true, pane: false), here])
            == [false, false, true])
        // Drip cannot tell the pane: the app's word goes.
        #expect(arrivals([WhenFocused.Front(app: false), WhenFocused.Front(app: true)]) == [false, true])
    }

    @Test func thePermissionEventsAreMarked() throws {
        #expect(try AgentHook.event(agent: .claude, payload: Self.claude).asksPermission)
        #expect(try AgentHook.event(agent: .codex, payload: Self.codex).asksPermission)
        let notice = #"{"hook_event_name":"Notification","message":"m","notification_type":"permission_prompt"}"#
        #expect(try !AgentHook.event(agent: .claude, payload: notice).asksPermission)
        #expect(AgentHook.Agent.codex.holdsPromptForHook)
        #expect(!AgentHook.Agent.claude.holdsPromptForHook)
    }
}
#endif
