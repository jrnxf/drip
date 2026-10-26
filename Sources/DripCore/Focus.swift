/// What an agent's card does while the terminal the agent runs in is in front: you are likely
/// watching it already.
public enum WhenFocused: String, CaseIterable, Sendable {
    /// A card that counts down comes without a sound and with a short countdown. A card that waits
    /// for you shows as any other.
    case quiet
    /// As any other card.
    case show
    /// No card at all, not even one that waits for you, but only when drip knows the agent's own
    /// tmux pane is the one in front and you used the keyboard or mouse within `away_after`;
    /// when it only knows the terminal app is, as `quiet`.
    case skip

    public static let `default` = WhenFocused.quiet

    /// How long a quiet card counts down.
    public static let quietSeconds = 1.5

    /// How recently you must have used the keyboard or mouse for drip to take it that you are at the
    /// screen, watching the terminal in front, unless `away_after` says otherwise. A minute is long
    /// enough to read what an agent wrote without touching anything, and short enough that a terminal
    /// left in front while you are away still raises its cards.
    public static let defaultAwayAfter = 60.0

    /// Where the agent's terminal is, as drip can tell.
    public struct Front: Equatable, Sendable {
        /// Whether the app a click on the card brings forward is the frontmost app.
        public var app: Bool
        /// Whether the agent's own tmux pane is the one showing, in an attached client; nil when
        /// drip cannot tell, as outside tmux.
        public var pane: Bool?
        /// Seconds since the keyboard or mouse was last used; nil when drip cannot tell, which counts
        /// as just now.
        public var idle: Double?

        public init(app: Bool, pane: Bool? = nil, idle: Double? = nil) {
            self.app = app
            self.pane = pane
            self.idle = idle
        }

        /// Whether you are likely at the screen, having used the keyboard or mouse within `awayAfter`
        /// seconds: a terminal in front of an empty room is not watched.
        func present(awayAfter: Double) -> Bool {
            (idle ?? 0) < awayAfter
        }
    }

    /// `card` as it shows while the terminal is where `front` says, or nil when it does not show.
    /// Several sessions often share one terminal app, so a card is only ever skipped on the pane's
    /// word, not the app's, and a card that waits for you is only ever skipped, never quieted: it is
    /// on you either way.
    public func apply(to card: Card, front: Front, awayAfter: Double = WhenFocused.defaultAwayAfter) -> Card? {
        guard self != .show, front.present(awayAfter: awayAfter) else { return card }
        let inFront: Bool
        if let pane = front.pane {
            inFront = pane && front.app
        } else {
            inFront = front.app
        }
        guard inFront else { return card }
        if self == .skip, front.pane == true { return nil }
        guard !card.waits else { return card }
        var card = card
        card.sound = .none
        card.seconds = min(card.seconds, Self.quietSeconds)
        return card
    }
}

extension CardResolver {
    /// `DRIP_WHEN_FOCUSED`, then the config's `when_focused`, then quiet.
    public var whenFocused: WhenFocused {
        environment.whenFocused ?? config.whenFocused ?? .default
    }

    /// `DRIP_AWAY_AFTER`, then the config's `away_after`, then a minute.
    public var awayAfter: Double {
        environment.awayAfter ?? config.awayAfter ?? WhenFocused.defaultAwayAfter
    }

    /// `DRIP_AGENT_CARDS`, then the config's `agent_cards`, then all.
    public var agentCards: AgentHook.Cards {
        environment.agentCards ?? config.agentCards ?? .default
    }

    /// `DRIP_DONE_AFTER`, then the config's `done_after`, then 0: every done card shows.
    public var doneAfter: Double {
        environment.doneAfter ?? config.doneAfter ?? 0
    }
}
