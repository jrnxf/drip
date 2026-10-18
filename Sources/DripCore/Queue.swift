/// One drip's place in the queue that shows cards one after another across every drip of a user.
///
/// A ticket is a file named for when it was queued and the pid that shows its cards. It holds the
/// cards that carry an id, so a newer drip's card can replace them. When a showing drip takes over
/// a newer ticket's card on screen, it marks that card's id as claimed, and the newer drip then
/// skips it.
public struct QueueTicket: Equatable, Sendable {
    public var name: String
    public var pid: Int32
    /// The ticket's cards that carry an id; only these can be replaced.
    public var cards: [Card]
    /// The ids of this ticket's cards that a showing drip took over.
    public var claimed: Set<String>

    /// Parses a ticket file name: a 20-digit timestamp, a hyphen and a pid. Nil for anything else,
    /// such as a claim file or a ticket still being written.
    public init?(name: String, cards: [Card] = [], claimed: Set<String> = []) {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        let digits = { (part: Substring) in !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } }
        guard parts.count == 2, parts[0].count == 20, digits(parts[0]), digits(parts[1]), let pid = Int32(parts[1])
        else { return nil }
        self.name = name
        self.pid = pid
        self.cards = cards
        self.claimed = claimed
    }

    /// The file name for a ticket queued at `stamp` nanoseconds since 1970. Names sort in the
    /// order the tickets were queued.
    public static func name(stamp: UInt64, pid: Int32) -> String {
        let digits = String(stamp)
        return String(repeating: "0", count: max(20 - digits.count, 0)) + digits + "-\(pid)"
    }

    /// The file beside a ticket that lists its claimed ids.
    public static func claimName(for ticket: String) -> String {
        ticket + ".claimed"
    }
}

/// Decides which cards a newer card with the same id replaces.
public enum CardReplacement {
    /// Whether `card`, from `ticket`, should not be shown: a newer ticket whose drip is still alive
    /// has a card with the same id, or a showing drip already took this card over.
    public static func isReplaced(
        _ card: Card, in ticket: QueueTicket, queue: [QueueTicket], isAlive: (Int32) -> Bool
    ) -> Bool {
        guard let id = card.id else { return false }
        if ticket.claimed.contains(id) { return true }
        return queue.contains { other in
            other.name > ticket.name && other.cards.contains { $0.id == id } && isAlive(other.pid)
        }
    }

    /// The newest card from a ticket queued after `source` that should take the place of `showing`
    /// on screen, and the ticket it came from. Nil when there is none, or when the newest card with
    /// the same id cannot swap in place and has to wait for its own turn instead.
    public static func replacement(
        for showing: Card, after source: String, queue: [QueueTicket], isAlive: (Int32) -> Bool
    ) -> (ticket: String, card: Card)? {
        guard let id = showing.id else { return nil }
        for ticket in queue.sorted(by: { $0.name > $1.name }) where ticket.name > source {
            guard !ticket.claimed.contains(id), let card = ticket.cards.last(where: { $0.id == id }),
                  isAlive(ticket.pid)
            else { continue }
            return canSwap(showing, for: card) ? (ticket.name, card) : nil
        }
        return nil
    }

    /// The cards in order, keeping only the newest card for each id; cards without an id all stay.
    public static func latest(_ cards: [Card]) -> [Card] {
        cards.indices.filter { index in
            guard let id = cards[index].id else { return true }
            return !cards[(index + 1)...].contains { $0.id == id }
        }.map { cards[$0] }
    }

    /// Whether `new` can take the place of `old` on screen. A card that asks a question reports its
    /// click to the drip that showed it, so it never swaps; and the new card must sit in the same
    /// place.
    public static func canSwap(_ old: Card, for new: Card) -> Bool {
        !old.asksQuestion && !new.asksQuestion && old.position == new.position
    }
}
