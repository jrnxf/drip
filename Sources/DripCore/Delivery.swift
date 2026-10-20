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

    public init(cards: [Card], record: Bool = true) {
        self.cards = cards
        self.record = record
    }

    private enum CodingKeys: String, CodingKey {
        case cards, record
    }

    /// A request from a drip that predates `record` is recorded.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cards = try container.decode([Card].self, forKey: .cards)
        record = try container.decodeIfPresent(Bool.self, forKey: .record) ?? true
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

/// What a drip does with its cards when the screen is locked at their turn. Locked or not, the
/// cards go into the history when `record` is true.
public enum LockedScreen: Equatable, Sendable {
    /// Hold them with every other background drip's, to show together once the screen unlocks.
    case pool(record: Bool)
    /// Wait here until the screen unlocks, then show them: the caller is waiting for the outcome.
    case wait(record: Bool)
    /// Show them anyway, and keep them out of the history: `drip demo`.
    case ignore

    /// Adds the cards to `history`, unless they are kept out of it.
    public func record(_ cards: [Card], missed: Bool, in history: CardHistory) throws {
        switch self {
        case let .pool(record), let .wait(record):
            if record { try history.record(cards, missed: missed) }
        case .ignore:
            break
        }
    }
}
