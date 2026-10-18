import Foundation

/// How blip hands cards to the screen.
///
/// By default blip returns as soon as the cards are checked: a background blip shows them, so a
/// script, hook or `blip run` never waits on a card. Cards from every blip queue up and show one
/// after another.
public enum Delivery: Equatable, Sendable {
    /// Hand the cards to a background blip and return at once.
    case background
    /// Show the cards and return once they have gone.
    case wait

    /// `--wait` waits, and so does a button with nothing to open: its click is only reported
    /// through blip's exit status.
    public static func choose(for cards: [Card], wait: Bool) -> Delivery {
        if wait || cards.contains(where: \.asksQuestion) {
            return .wait
        }
        return .background
    }
}

/// The cards a background blip shows, as JSON on its standard input.
public struct BackgroundRequest: Equatable, Sendable, Codable {
    public var cards: [Card]

    public init(cards: [Card]) {
        self.cards = cards
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> BackgroundRequest {
        try JSONDecoder().decode(BackgroundRequest.self, from: data)
    }
}
