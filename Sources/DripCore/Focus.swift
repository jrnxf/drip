/// What an agent's card that counts down, such as "my-app is done", does while the terminal the
/// agent runs in is in front: you are likely watching it already.
public enum WhenFocused: String, CaseIterable, Sendable {
    /// No sound, and a short countdown.
    case quiet
    /// As any other card.
    case show
    /// No card at all, but only when drip knows the agent's own tmux pane is the one in front;
    /// when it only knows the terminal app is, as `quiet`.
    case skip

    public static let `default` = WhenFocused.quiet

    /// How long a quiet card counts down.
    public static let quietSeconds = 1.5

    /// Where the agent's terminal is, as drip can tell.
    public struct Front: Equatable, Sendable {
        /// Whether the app a click on the card brings forward is the frontmost app.
        public var app: Bool
        /// Whether the agent's own tmux pane is the one showing, in an attached client; nil when
        /// drip cannot tell, as outside tmux.
        public var pane: Bool?

        public init(app: Bool, pane: Bool? = nil) {
            self.app = app
            self.pane = pane
        }
    }

    /// `card` as it shows while the terminal is where `front` says, or nil when it does not show.
    /// A card that waits for you always shows: it is on you either way. Several sessions often
    /// share one terminal app, so a card is only ever skipped on the pane's word, not the app's.
    public func apply(to card: Card, front: Front) -> Card? {
        guard !card.waits, self != .show else { return card }
        let inFront: Bool
        if let pane = front.pane {
            inFront = pane && front.app
        } else {
            inFront = front.app
        }
        guard inFront else { return card }
        if self == .skip, front.pane == true { return nil }
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
}
