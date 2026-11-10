#if !os(WASI)
import Foundation

/// The config file as one hook event reads it: loaded on first use, and the same afterwards, so the
/// debug log and the card's settings agree. Each event makes its own, so an edit between two
/// events is seen by the second.
final class ConfigSnapshot {
    private let load: () throws -> ConfigFile
    private(set) lazy var file: Result<ConfigFile, Error> = Result(catching: load)

    init(load: @escaping () throws -> ConfigFile) {
        self.load = load
    }
}

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
        /// Called with a waiting card skipped because you were watching, and when the session's
        /// waiting record was written, so the card can come back with `resurfaced` if the agent
        /// still waits `WhenFocused.resurfaceDelay` seconds on.
        public var resurface: (Card, Double) -> Void
        /// Whether a card would wait for nobody now: the screen is locked, or `drip pause` holds cards.
        public var away: () -> Bool
        /// Reads the config file `environment` points at. An event calls it at most once, whether for
        /// the debug log or for the card's settings.
        public var loadConfig: ([String: String]) throws -> ConfigFile
        /// The settings from the config file `loadConfig` read and `environment`.
        public var resolver: (ConfigFile, [String: String]) throws -> CardResolver
        /// The machine the event came from, for an agent `drip follow` hears from; nil for one on this Mac.
        public var origin: Origin?
        /// Whether the event may show a card: false for one too old when `drip follow` heard it,
        /// which still takes away what it would have taken away.
        public var showsCards: Bool
        public var now: () -> Date
        /// The drip that asks, as the debug log names it.
        public var process: DebugLog.Process
        /// The lines a card shows, which tell whether a permission card shows its whole request:
        /// measured as the card draws them on a Mac, estimated elsewhere.
        public var shownText: (Card) -> ShownText

        public init(
            environment: [String: String], hasGUISession: Bool, isInstalled: @escaping (String) -> Bool,
            front: @escaping (Card) -> WhenFocused.Front, paneShowing: @escaping (Card) -> Bool? = { _ in nil },
            resurface: @escaping (Card, Double) -> Void = { _, _ in }, away: @escaping () -> Bool = { false },
            loadConfig: @escaping ([String: String]) throws -> ConfigFile = { try ConfigLoader.load(environment: $0) },
            resolver: @escaping (ConfigFile, [String: String]) throws -> CardResolver, origin: Origin? = nil,
            showsCards: Bool = true, now: @escaping () -> Date = Date.init, process: DebugLog.Process = .hook,
            shownText: @escaping (Card) -> ShownText = ShownText.init(estimating:)
        ) {
            self.process = process
            self.shownText = shownText
            self.environment = environment
            self.hasGUISession = hasGUISession
            self.isInstalled = isInstalled
            self.front = front
            self.paneShowing = paneShowing
            self.resurface = resurface
            self.away = away
            self.loadConfig = loadConfig
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
        agent: Agent, payload: String, flags: CardFlags = CardFlags(), policy: Policy = Policy(),
        in surroundings: Surroundings
    ) throws -> Card? {
        let environment = surroundings.environment
        // The config file is read once for the event, and only when something asks for it.
        let config = ConfigSnapshot { try surroundings.loadConfig(environment) }
        let log = DebugLog(
            path: DebugLog.path(environment: environment), process: surroundings.process,
            enabled: DebugLog.isEnabled(environment: environment) { try config.file.get() })
        func note(_ event: String, _ decision: String, _ fields: [(String, String?)] = []) {
            // A card decision that stopped before drip asked which app is in front says so.
            let unasked: [(String, String?)] = event == "card" && !fields.contains { $0.0 == "frontmost" }
                ? [("idle_seconds", "unknown"), ("frontmost", "unknown"), ("topmost_visible", "unknown")] : []
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
            // With --approve, a permission card says what the call would do, never only what the
            // agent says it does: a description can say anything about the command it describes.
            if policy.approve, found.asksPermission, origin == nil { found.detail = found.request }
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
        var resolver = try surroundings.resolver(try config.file.get(), environment)
        if let origin {
            resolver.environment.sender = origin.activate
            resolver.environment.pane = nil
            resolver.environment.forwarded = [:]
        }
        // A done card you chose not to see still takes away the card the session waits on, as it
        // would have replaced it. Which cards show does not depend on the session being known: only
        // the lookups by its id do.
        let turnStarted = id.flatMap { state.turnStarted(id: $0, now: surroundings.now()) }
        if skipsDone(event, policy: policy, turnStarted: turnStarted, now: surroundings.now().timeIntervalSince1970) {
            var took = false
            if let id, state.takeWaiting(Clear(id: id), now: surroundings.now()) {
                took = true
                try surroundings.dismissals.request(id: id)
            }
            let turn = turnStarted.map { surroundings.now().timeIntervalSince1970 - $0 }
            note("card", "skip", eventFields + [
                ("reason", "done_card_filtered"), ("only", policy.only?.rawValue),
                ("min_turn", "\(policy.minTurn)"), ("turn_seconds", turn.map { String(format: "%.1f", $0) }),
                ("took_waiting", "\(took)"),
            ])
            return nil
        }
        var card = try resolver.resolve(kind: event.kind, title: title, flags: flags)
        // A remote card's click runs only `drip follow --on-click`, never anything from the event.
        if let origin { card.onClick = origin.click }
        if let id = card.id {
            if card.waits {
                try? state.noteWaiting(id: id, tool: event.waitsOn, now: surroundings.now())
            } else {
                state.noteDone(id: id)
            }
        }
        let looked = decideFocus(
            card, surroundings: surroundings, resolver: resolver, log: log, fields: eventFields, resurfacing: false, note: note)
        guard let shown = looked.card else { return nil }
        // The card goes by its id when the agent moves on, as one you answered in the terminal.
        guard event.asksPermission, origin == nil, policy.approve, shown.id != nil else { return shown }
        // Held until you are back, the card would hold the agent's answer as long.
        if surroundings.away() {
            note("approve", "skip", eventFields + [("reason", "away")])
            return shown
        }
        // Codex holds its own prompt until the hook returns: with you at its terminal already, the
        // card only tells you, and the prompt shows at once.
        if agent.holdsPromptForHook,
           (looked.front ?? look(at: card, surroundings: surroundings, awayAfter: resolver.awayAfter)).watching(awayAfter: resolver.awayAfter)
        {
            note("approve", "skip", eventFields + [("reason", "watching_terminal")])
            return shown
        }
        // Allow on a card that cuts the command short, or cannot show all of it, would allow what
        // you never saw: the card only tells, and the terminal asks.
        guard let asking = asking(shown, request: event.request, shownText: surroundings.shownText) else {
            note("approve", "skip", eventFields + [("reason", "request_not_shown_whole")])
            return shown
        }
        note("approve", "ask", eventFields + [("wait_seconds", "\(Int(Defaults.approveWait))")])
        return asking
    }

    /// `card`, a permission card, with Allow and Deny: a click on either is the agent's answer, which
    /// `drip hook` prints as `Approval.output`. Nothing clicked in `Defaults.approveWait` seconds,
    /// or a click on the card itself, leaves the answer to the terminal. Its detail is `request`,
    /// what the call would do, whatever detail it had. Nil when the card cannot show all of the
    /// request, as `shownText` lays the card out: without one, when the request runs past the
    /// detail's last line, or when it holds characters the card does not draw, which could hide part
    /// of a command from you.
    public static func asking(
        _ card: Card, request: String?, shownText: (Card) -> ShownText = ShownText.init(estimating:)
    ) -> Card? {
        guard let request, isDrawable(request), let detail = CardText.line(request) else { return nil }
        var card = card
        card.detail = detail
        card.action = CardAction(label: "Allow", open: nil, decline: "Deny")
        card.waitLimit = Defaults.approveWait
        // Lines break at spaces, which they drop, or inside a word too long for a line.
        let shown = shownText(card).detail.joined().filter { !$0.isWhitespace }
        guard shown == detail.filter({ !$0.isWhitespace }) else { return nil }
        return card
    }

    /// Whether every character of `text` shows on a card as it is: no control character but line
    /// breaks and tabs, which show as spaces, and no format character, such as a bidi control or a
    /// zero-width space. A card drops the controls and the bidi controls, and the terminal escape
    /// sequences they start with all the text inside, so a command could run more than it shows.
    static func isDrawable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control: return scalar == "\n" || scalar == "\t" || scalar == "\r"
            case .format: return false
            default: return true
            }
        }
    }

    /// Where the terminal is for `card`, asking about its pane only when that decides it: the
    /// terminal app in front, and you at it.
    static func look(at card: Card, surroundings: Surroundings, awayAfter: Double) -> WhenFocused.Front {
        var front = surroundings.front(card)
        if front.pane == nil, front.app, front.present(awayAfter: awayAfter) {
            front.pane = surroundings.paneShowing(card)
        }
        return front
    }

    /// The card a waiting card skipped while you were watching becomes `WhenFocused.resurfaceDelay`
    /// seconds on, or nil: the agent moved on (a later event for the session took its waiting record
    /// away or replaced it, whose time then differs from `noted`), or you are watching still.
    public static func resurfaced(
        _ card: Card, agent: Agent, noted: Double, in surroundings: Surroundings
    ) throws -> Card? {
        let environment = surroundings.environment
        let config = ConfigSnapshot { try surroundings.loadConfig(environment) }
        let log = DebugLog(
            path: DebugLog.path(environment: environment), process: surroundings.process,
            enabled: DebugLog.isEnabled(environment: environment) { try config.file.get() })
        func note(_ event: String, _ decision: String, _ fields: [(String, String?)] = []) {
            log.record(event, decision, [("agent", agent.rawValue), ("machine", surroundings.origin?.machine)] + fields)
        }
        let fields: [(String, String?)] = [("id", card.id.map(DebugLog.short(id:)))]
        guard let id = card.id, surroundings.state.waiting(id: id, now: surroundings.now())?.time == noted else {
            note("resurface", "skip", fields + [("reason", "no_longer_waiting")])
            return nil
        }
        let resolver = try surroundings.resolver(try config.file.get(), environment)
        return decideFocus(
            card, surroundings: surroundings, resolver: resolver, log: log, fields: fields, resurfacing: true, note: note).card
    }

    /// `card` as it shows given where the terminal is, or nil when you are watching, and where the
    /// terminal was, when drip looked. A waiting card skipped for it is handed to
    /// `surroundings.resurface`, unless this is already its second look.
    private static func decideFocus(
        _ card: Card, surroundings: Surroundings, resolver: CardResolver, log: DebugLog, fields eventFields: [(String, String?)],
        resurfacing: Bool, note: (String, String, [(String, String?)]) -> Void
    ) -> (card: Card?, front: WhenFocused.Front?) {
        let origin = surroundings.origin
        // You may be watching the agent's terminal already. Asking tmux about the pane costs a
        // command, so only when it matters: its terminal in front, and you at it. For an agent on
        // another machine, drip cannot tell, so it takes you not to be watching.
        let whenFocused = resolver.whenFocused
        guard whenFocused != .show else {
            note("card", "show", eventFields + [("reason", "when_focused_show"), ("waits", "\(card.waits)")])
            return (card, nil)
        }
        var front = surroundings.front(card)
        var query: [(String, String?)] = []
        if origin == nil, front.pane == nil, front.app, front.present(awayAfter: resolver.awayAfter) {
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
        if unknownRemote { front = WhenFocused.Front(app: false, pane: false, idle: front.idle, frontmost: front.frontmost, topmostVisible: front.topmostVisible) }
        let shown = whenFocused.apply(to: card, front: front, awayAfter: resolver.awayAfter)
        // A waiting card you were watching comes back once, if the agent still waits and you are not.
        if shown == nil, !resurfacing, card.waits, let id = card.id,
           let noted = surroundings.state.waiting(id: id, now: surroundings.now())?.time
        {
            surroundings.resurface(card, noted)
        }
        if log.enabled {
            let reason = shown == nil ? "focused_skip" : shown != card ? "focused_quiet" : "not_focused_or_away"
            note(resurfacing ? "resurface" : "card", shown == nil ? "skip" : "show", eventFields + [
                ("reason", reason), ("waits", "\(card.waits)"), ("when_focused", whenFocused.rawValue),
                ("away_after", "\(resolver.awayAfter)"), ("idle_seconds", front.idle.map { String(format: "%.1f", $0) } ?? "unknown"),
                ("frontmost", front.frontmost ?? "unknown"), ("topmost_visible", front.topmostVisible ?? "unknown"), ("activate", card.activate), ("app_in_front", "\(front.app)"),
                ("pane", card.pane?.debugName),
                ("pane_showing", front.pane.map { "\($0)" }), ("remote_pane_unknown", unknownRemote ? "true" : nil),
            ] + query)
        }
        return (shown, front)
    }
}
#endif
