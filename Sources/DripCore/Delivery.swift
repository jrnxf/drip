#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif

/// How drip hands cards to the screen.
///
/// By default drip returns as soon as the cards are checked: a background drip shows them, so a
/// script, hook or `drip run` never waits on a card. Cards from every drip queue up and show one
/// after another.
public enum Delivery: Equatable, Sendable {
    /// Hand the cards to a background drip and return at once.
    case background
    /// Show the cards and return once they have gone.
    case wait

    /// `--wait` waits, and so does a button with nothing to open: its click is only reported
    /// through drip's exit status.
    public static func choose(for cards: [Card], wait: Bool) -> Delivery {
        if wait || cards.contains(where: \.asksQuestion) {
            return .wait
        }
        return .background
    }
}

/// The cards a background drip shows, as JSON on its standard input.
public struct BackgroundRequest: Equatable, Sendable, Codable {
    public var cards: [Card]
    /// False for cards shown again from the history, which keeps them already.
    public var record: Bool
    /// Set when the cards are already on screen in a stack that hands them on, to show where they
    /// are instead of dropping them in again.
    public var handOff: StackHandOff?
    /// Set for a waiting card skipped because you were watching: the background drip waits, then
    /// looks again and shows the card only if the agent still waits and you are not watching.
    public var resurface: Resurface?

    /// What a background drip needs to look again at a skipped waiting card.
    public struct Resurface: Equatable, Sendable, Codable {
        /// The agent, as `AgentHook.Agent` names it.
        public var agent: String
        /// When the session's waiting record was written, which a later event changes or removes.
        public var noted: Double
        /// Seconds to wait before looking.
        public var delay: Double

        public init(agent: String, noted: Double, delay: Double = WhenFocused.resurfaceDelay) {
            self.agent = agent
            self.noted = noted
            self.delay = delay
        }
    }

    public init(cards: [Card], record: Bool = true) {
        self.cards = cards
        self.record = record
    }

    /// A request to look again at `cards`, the waiting card a hook skipped, after a delay.
    public init(cards: [Card], resurface: Resurface) {
        self.cards = cards
        record = true
        self.resurface = resurface
    }

    /// A request for the cards `handOff` hands on, which are recorded already.
    public init(handOff: StackHandOff) {
        cards = handOff.cards.map(\.card)
        record = false
        self.handOff = handOff
    }

    private enum CodingKeys: String, CodingKey {
        case cards, record, handOff, resurface
    }

    /// A request from a drip that predates `record` is recorded, and one that predates `handOff`
    /// hands nothing on.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cards = try container.decode([Card].self, forKey: .cards)
        record = try container.decodeIfPresent(Bool.self, forKey: .record) ?? true
        handOff = try container.decodeIfPresent(StackHandOff.self, forKey: .handOff)
        resurface = try container.decodeIfPresent(Resurface.self, forKey: .resurface)
    }

    /// What the background drip does with the cards while the screen is locked.
    public var locked: LockedScreen { .pool(record: record) }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> BackgroundRequest {
        try JSONDecoder().decode(BackgroundRequest.self, from: data)
    }
}

/// The cards a stack at the notch hands on to a background drip when the drip that shows it exits,
/// as a drip that waited for its question's answer does: the background drip shows them on, as
/// they are, in a stack with the same settings.
public struct StackHandOff: Equatable, Sendable, Codable {
    public var settings: StackSettings
    /// Top to bottom.
    public var cards: [HandedCard]
    /// When the cards were as they are, in seconds since 1970, so the drip they are handed on to
    /// shows them as they are by the time it does; nil to show them as they are.
    public var time: Double?

    public init(settings: StackSettings, cards: [HandedCard], time: Double? = nil) {
        self.settings = settings
        self.cards = cards
        self.time = time
    }

    /// A single card at the notch that started to leave at `time`, in seconds since 1970, from an
    /// open capsule whose top was at `top`: the background drip plays its exit on from there.
    public static func leaving(_ card: Card, top: Double, at time: Double) -> StackHandOff {
        StackHandOff(
            settings: StackSettings(mode: .chain, max: 1),
            cards: [HandedCard(card: card, top: top, remaining: 0, isWaiting: false, leaving: 0)], time: time)
    }

    /// The cards as they are at `now`, in seconds since 1970: each `aged` by the time since `time`.
    public func cards(at now: Double) -> [HandedCard] {
        guard let time else { return cards }
        let age = max(now - time, 0)
        return cards.map { $0.aged(by: age) }
    }
}

/// A card handed on as it is on screen.
public struct HandedCard: Equatable, Sendable, Codable {
    public var card: Card
    /// Where its capsule's top is heading, from the notch down; for a card that is leaving, where it
    /// was when it started to.
    public var top: Double
    /// Seconds left on its countdown, or on its wait limit while it still waits.
    public var remaining: Double
    public var isWaiting: Bool
    /// How long ago it started to leave; nil while it shows.
    public var leaving: Double?
    /// Whether it left rising at once rather than gathering in place first; nil for gathering, as
    /// from a drip that did not say.
    public var rises: Bool?
    /// Whether it left sinking away, as a push stack's card does as the next grows out of the
    /// overflow pill; nil for not, as from a drip that did not say.
    public var sinks: Bool?
    /// The springs still taking its top there, as it glides into a gap; none at rest.
    public var glide: [SpringMotion]

    public init(
        card: Card, top: Double, remaining: Double, isWaiting: Bool, leaving: Double? = nil,
        rises: Bool? = nil, sinks: Bool? = nil, glide: [SpringMotion] = []
    ) {
        self.card = card
        self.top = top
        self.remaining = remaining
        self.isWaiting = isWaiting
        self.leaving = leaving
        self.rises = rises
        self.sinks = sinks
        self.glide = glide
    }

    /// Where its capsule's top is drawn.
    public var drawnTop: Double {
        glide.reduce(top) { $0 - $1.left }
    }

    /// The card `age` seconds on: that much less time left, and that much further into leaving and
    /// on its glide.
    public func aged(by age: Double) -> HandedCard {
        var card = self
        card.remaining = max(remaining - age, 0)
        card.leaving = leaving.map { $0 + age }
        card.glide = glide.map { SpringMotion(change: $0.change, spring: $0.spring, elapsed: $0.elapsed + age) }
            .filter { $0.elapsed < $0.spring.settlingTime }
        return card
    }
}

/// What a drip does with its cards when the screen is locked at their turn. Locked or not, the
/// cards go into the history when `record` is true.
public enum LockedScreen: Equatable, Sendable {
    /// Hold them with every other background drip's, to show together once the screen unlocks.
    case pool(record: Bool)
    /// Wait here until the screen unlocks, then show them: the caller is waiting for the outcome.
    case wait(record: Bool)

    /// Adds the cards to `history`, unless they are kept out of it.
    public func record(
        _ cards: [Card], missed: Bool, in history: CardHistory, shown: (Card) -> ShownText? = { _ in nil }
    ) throws {
        switch self {
        case let .pool(record), let .wait(record):
            if record { try history.record(cards, missed: missed, shown: shown) }
        }
    }
}
