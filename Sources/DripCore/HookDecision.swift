#if !os(WASI)
import Foundation

extension AgentHook {
    /// What drip can tell around a hook event, which decides whether and how its card shows: what
    /// `drip hook` reads on this Mac, and what `drip follow` hears from an agent on another machine.
    public struct Surroundings {
        /// The environment the rules read: `DRIP_HOOK`, whether anyone attends the session, the
        /// `DRIP_*` settings, and where the config and state are.
        public var environment: [String: String]
        /// Whether there is a GUI session to show cards in.
        public var hasGUISession: Bool
        /// Whether an app with the bundle identifier is installed.
        public var isInstalled: (String) -> Bool
        /// Where the terminal a click on the card brings forward is.
        public var front: (Card) -> WhenFocused.Front
        /// Whether the card's pane is the one its terminal shows, which `front` leaves to this when
        /// it says nil; nil when drip cannot tell.
        public var paneShowing: (Card) -> Bool?
        /// The settings from the config file and `environment`.
        public var resolver: ([String: String]) throws -> CardResolver
        /// The machine the event came from, for an agent `drip follow` hears from; nil for one on this Mac.
        public var origin: Origin?
        /// Whether the event may show a card: false for one too old when `drip follow` heard it,
        /// which still takes away what it would have taken away.
        public var showsCards: Bool
        public var now: () -> Date
        /// The drip that asks, as the debug log names it.
        public var process: DebugLog.Process

        public init(
            environment: [String: String], hasGUISession: Bool, isInstalled: @escaping (String) -> Bool,
            front: @escaping (Card) -> WhenFocused.Front, paneShowing: @escaping (Card) -> Bool? = { _ in nil },
            resolver: @escaping ([String: String]) throws -> CardResolver, origin: Origin? = nil,
            showsCards: Bool = true, now: @escaping () -> Date = Date.init, process: DebugLog.Process = .hook
        ) {
            self.process = process
            self.environment = environment
            self.hasGUISession = hasGUISession
            self.isInstalled = isInstalled
            self.front = front
            self.paneShowing = paneShowing
            self.resolver = resolver
            self.origin = origin
            self.showsCards = showsCards
            self.now = now
        }

        var state: AgentState { AgentState(environment: environment) }
        var dismissals: DismissRequests { DismissRequests(environment: environment) }
    }

    /// What a hook payload makes drip do, by the same rules wherever the agent runs: takes away the
    /// card the session waits on, and returns the card to show, or nil for none. Notes what the
    /// session waits on and when its turn started. Throws a `UsageError` for a payload it cannot
    /// read or a `DRIP_HOOK` it does not know, and a `ConfigError` for an invalid config.
    public static func card(
        agent: Agent, payload: String, flags: CardFlags = CardFlags(), in surroundings: Surroundings
    ) throws -> Card? {
        let environment = surroundings.environment
        let log = DebugLog(environment: environment, process: surroundings.process)
        func note(_ event: String, _ decision: String, _ fields: [(String, String?)] = []) {
            // A card decision that stopped before drip asked which app is in front says so.
            let unasked: [(String, String?)] = event == "card" && !fields.contains { $0.0 == "frontmost" }
                ? [("idle_seconds", "unknown"), ("frontmost", "unknown")] : []
            log.record(event, decision, [("agent", agent.rawValue), ("machine", surroundings.origin?.machine)] + fields + unasked)
        }
        // A session nobody attends, such as `claude -p` in a pipeline, or one an orchestrator
        // silenced with DRIP_HOOK=off: nothing to show, nothing to take away, nothing to fail.
        guard try speaks(for: agent, environment: environment) else {
            note("card", "skip", [("reason", (try? setting(environment: environment)) == .off ? "drip_hook_off" : "unattended")])
            return nil
        }
        if payload.utf8.count > payloadLimit {
            note("card", "error", [("reason", "payload_too_large")])
            throw UsageError("the hook payload is larger than 4 MB")
        }
        let origin = surroundings.origin
        let state = surroundings.state
        let event: Event
        // DRIP_HOOK=attention: the done card at the end of a turn needs nobody, but still takes
        // away the card the session waits on.
        switch try outcome(agent: agent, payload: payload, environment: environment) {
        case .nothing:
            note("card", "skip", [("reason", "no_card")])
            return nil
        case var .clear(clear):
            if let origin { clear.id = origin.qualified(clear.id) }
            // You answered in the terminal: the card that said the agent needs you would only be
            // wrong now. One file read when no card waits, as on most tool calls.
            let took = state.takeWaiting(clear, now: surroundings.now())
            if took { try surroundings.dismissals.request(id: clear.id) }
            note("clear", "clear", [
                ("id", DebugLog.short(id: clear.id)), ("took_waiting", "\(took)"), ("starts_turn", "\(clear.startsTurn)"),
            ])
            if clear.startsTurn { try? state.noteTurn(id: clear.id, now: surroundings.now()) }
            return nil
        case var .card(found):
            if let origin { found.id = found.id.map(origin.qualified) }
            event = found
        }
        let id = event.id
        let eventFields: [(String, String?)] = [("kind", event.kind), ("id", id.map(DebugLog.short(id:)))]
        // Claude's permission_prompt notification, when a PermissionRequest hook already showed
        // the card for it, with what Claude wants to do.
        if event.isPermissionNotice, let id, state.waiting(id: id, now: surroundings.now())?.tool != nil {
            note("card", "skip", eventFields + [("reason", "permission_already_shown")])
            return nil
        }
        // An event too old to show still takes away the card the session waits on, as its card
        // would have replaced it.
        guard surroundings.showsCards else {
            var took = false
            if let id, state.takeWaiting(Clear(id: id), now: surroundings.now()) {
                took = true
                try surroundings.dismissals.request(id: id)
            }
            note("card", "skip", eventFields + [("reason", "stale_event"), ("took_waiting", "\(took)")])
            return nil
        }
        guard surroundings.hasGUISession else {
            note("card", "skip", eventFields + [("reason", "no_gui_session")])
            return nil
        }
        var flags = event.filling(flags)
        flags.icon = flags.icon ?? agent.icon(installed: surroundings.isInstalled)
        // The title starts with the project, or the agent's name when the payload names no folder.
        let name = event.directory.flatMap(projectName) ?? agent.displayName
        var project = name
        if let id, let directory = event.directory {
            // A folder on another machine is not the folder of the same path here: each machine's
            // folders are noted, and read apart, among their own.
            let machine = origin.map { "\($0.machine):" } ?? ""
            try? state.noteSession(id: id, directory: machine + directory, now: surroundings.now())
            // Two sessions in folders of the same name, such as two worktrees of one repo, read apart.
            if projectName(directory) != nil {
                let others = state.otherDirectories(than: id, now: surroundings.now()).compactMap { other in
                    other.hasPrefix(machine + "/") ? String(other.dropFirst(machine.count)) : nil
                }
                project = AgentState.project(directory, among: others)
            }
        }
        var title = event.title
        if title.hasPrefix(name + " ") {
            title = project + (origin.map { " on \($0.machine)" } ?? "") + title.dropFirst(name.count)
        }
        var resolver = try surroundings.resolver(environment)
        if let origin {
            resolver.environment.sender = origin.activate
            resolver.environment.pane = origin.pane
        }
        // A done card you chose not to see still takes away the card the session waits on, as it
        // would have replaced it.
        if let id, skipsDone(
            event, cards: resolver.agentCards, doneAfter: resolver.doneAfter,
            turnStarted: state.turnStarted(id: id, now: surroundings.now()),
            now: surroundings.now().timeIntervalSince1970)
        {
            let took = state.takeWaiting(Clear(id: id), now: surroundings.now())
            if took { try surroundings.dismissals.request(id: id) }
            let turn = state.turnStarted(id: id, now: surroundings.now()).map { surroundings.now().timeIntervalSince1970 - $0 }
            note("card", "skip", eventFields + [
                ("reason", "done_card_filtered"), ("agent_cards", resolver.agentCards.rawValue),
                ("done_after", "\(resolver.doneAfter)"), ("turn_seconds", turn.map { String(format: "%.1f", $0) }),
                ("took_waiting", "\(took)"),
            ])
            return nil
        }
        let card = try resolver.resolve(kind: event.kind, title: title, flags: flags)
        if let id = card.id {
            if card.waits {
                try? state.noteWaiting(id: id, tool: event.waitsOn, now: surroundings.now())
            } else {
                state.noteDone(id: id)
            }
        }
        // You may be watching the agent's terminal already. Asking about the pane costs a round trip
        // to another machine, so only when it matters: its terminal in front, and you at it. For an
        // agent there, only that machine's herdr can say whether its pane is in front; when it
        // cannot, drip takes you not to be watching.
        let whenFocused = resolver.whenFocused
        guard whenFocused != .show else {
            note("card", "show", eventFields + [("reason", "when_focused_show"), ("waits", "\(card.waits)")])
            return card
        }
        var front = surroundings.front(card)
        var query: [(String, String?)] = []
        if front.pane == nil, front.app, front.present(awayAfter: resolver.awayAfter) {
            let asked = Date()
            front.pane = surroundings.paneShowing(card)
            if log.enabled {
                query = [
                    ("query", card.pane.flatMap(\.debugQuery)),
                    ("answer", front.pane.map { $0 ? "showing" : "not_showing" } ?? "unknown"),
                    ("query_ms", "\(Int(Date().timeIntervalSince(asked) * 1000))"),
                ]
            }
        }
        let unknownRemote = origin != nil && front.pane == nil
        if unknownRemote { front = WhenFocused.Front(app: false, pane: false, idle: front.idle, frontmost: front.frontmost) }
        let shown = whenFocused.apply(to: card, front: front, awayAfter: resolver.awayAfter)
        if log.enabled {
            let reason = shown == nil ? "focused_skip" : shown != card ? "focused_quiet" : "not_focused_or_away"
            note("card", shown == nil ? "skip" : "show", eventFields + [
                ("reason", reason), ("waits", "\(card.waits)"), ("when_focused", whenFocused.rawValue),
                ("away_after", "\(resolver.awayAfter)"), ("idle_seconds", front.idle.map { String(format: "%.1f", $0) } ?? "unknown"),
                ("frontmost", front.frontmost ?? "unknown"), ("activate", card.activate), ("app_in_front", "\(front.app)"),
                ("pane", card.pane?.debugName), ("herdr_machine", card.pane?.herdrMachine),
                ("pane_showing", front.pane.map { "\($0)" }), ("remote_pane_unknown", unknownRemote ? "true" : nil),
            ] + query)
        }
        return shown
    }
}
#endif
