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
        /// The settings from the config file and `environment`.
        public var resolver: ([String: String]) throws -> CardResolver
        /// The machine the event came from, for an agent `drip follow` hears from; nil for one on this Mac.
        public var origin: Origin?
        public var now: () -> Date

        public init(
            environment: [String: String], hasGUISession: Bool, isInstalled: @escaping (String) -> Bool,
            front: @escaping (Card) -> WhenFocused.Front,
            resolver: @escaping ([String: String]) throws -> CardResolver, origin: Origin? = nil,
            now: @escaping () -> Date = Date.init
        ) {
            self.environment = environment
            self.hasGUISession = hasGUISession
            self.isInstalled = isInstalled
            self.front = front
            self.resolver = resolver
            self.origin = origin
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
        // A session nobody attends, such as `claude -p` in a pipeline, or one an orchestrator
        // silenced with DRIP_HOOK=off: nothing to show, nothing to take away, nothing to fail.
        guard try speaks(for: agent, environment: environment) else { return nil }
        if payload.utf8.count > payloadLimit {
            throw UsageError("the hook payload is larger than 4 MB")
        }
        let origin = surroundings.origin
        let state = surroundings.state
        let event: Event
        // DRIP_HOOK=attention: the done card at the end of a turn needs nobody, but still takes
        // away the card the session waits on.
        switch try outcome(agent: agent, payload: payload, environment: environment) {
        case .nothing:
            return nil
        case var .clear(clear):
            if let origin { clear.id = origin.qualified(clear.id) }
            // You answered in the terminal: the card that said the agent needs you would only be
            // wrong now. One file read when no card waits, as on most tool calls.
            if state.takeWaiting(clear, now: surroundings.now()) { try surroundings.dismissals.request(id: clear.id) }
            if clear.startsTurn { try? state.noteTurn(id: clear.id, now: surroundings.now()) }
            return nil
        case var .card(found):
            if let origin { found.id = found.id.map(origin.qualified) }
            event = found
        }
        let id = event.id
        // Claude's permission_prompt notification, when a PermissionRequest hook already showed
        // the card for it, with what Claude wants to do.
        if event.isPermissionNotice, let id, state.waiting(id: id, now: surroundings.now())?.tool != nil {
            return nil
        }
        guard surroundings.hasGUISession else { return nil }
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
            if state.takeWaiting(Clear(id: id), now: surroundings.now()) { try surroundings.dismissals.request(id: id) }
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
        // You may be watching the agent's terminal already. drip cannot tell whether this Mac shows
        // a pane on another machine, so it takes you not to be watching one.
        let front = origin == nil ? surroundings.front(card) : WhenFocused.Front(app: false, pane: false)
        return resolver.whenFocused.apply(to: card, front: front, awayAfter: resolver.awayAfter)
    }
}
#endif
