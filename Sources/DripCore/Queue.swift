import Foundation

/// One drip's place in the queue that shows cards one after another across every drip of a user.
///
/// A ticket is a file named for when it was queued, the pid that shows its cards and when that
/// process started, so a later process given the same pid is not taken for it. It holds the
/// cards, so a newer drip's card can replace them and a showing drip can adopt them into its stack.
/// When a showing drip takes over a newer ticket's card on screen, it marks that card as claimed,
/// by its id or by its place in the ticket, and the newer drip then skips it.
public struct QueueTicket: Equatable, Sendable {
    public var name: String
    public var pid: Int32
    /// When the process started, as `HeldCards.processStartTime` gives it; nil when it was gone
    /// before its ticket was written.
    public var start: UInt64?
    public var cards: [Card]
    /// The ids, and the `CardAdoption.claimKey`s, of this ticket's cards that a showing drip took over.
    public var claimed: Set<String>
    /// Whether a showing drip may adopt this ticket's cards: true for a background drip, which has
    /// nothing to report once its cards are on screen.
    public var adoptable: Bool

    /// Parses a ticket file name: a 20-digit timestamp, a hyphen and a pid, then a hyphen and the
    /// process's start time when it was known. Nil for anything else, such as a claim file or a
    /// ticket still being written.
    public init?(name: String, cards: [Card] = [], claimed: Set<String> = [], adoptable: Bool = false) {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        let digits = { (part: Substring) in !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } }
        guard (2...3).contains(parts.count), parts[0].count == 20, parts.allSatisfy(digits),
              let pid = Int32(parts[1])
        else { return nil }
        let start = parts.count == 3 ? UInt64(parts[2]) : nil
        if parts.count == 3, start == nil { return nil }
        self.name = name
        self.pid = pid
        self.start = start
        self.cards = cards
        self.claimed = claimed
        self.adoptable = adoptable
    }

    /// The file name for a ticket queued at `stamp` nanoseconds since 1970. Names sort in the
    /// order the tickets were queued.
    public static func name(stamp: UInt64, pid: Int32, start: UInt64? = nil) -> String {
        let digits = String(stamp)
        return String(repeating: "0", count: max(20 - digits.count, 0)) + digits + "-\(pid)"
            + (start.map { "-\($0)" } ?? "")
    }

    /// The file beside a ticket that lists its claimed ids.
    public static func claimName(for ticket: String) -> String {
        ticket + ".claimed"
    }

    /// Whether a showing drip adopted every one of this ticket's cards, so its own drip has nothing
    /// left to show.
    public var isFullyAdopted: Bool {
        !cards.isEmpty && cards.indices.allSatisfy { claimed.contains(CardAdoption.claimKey(index: $0)) }
    }
}

/// What a ticket file holds.
public struct TicketContents: Equatable, Sendable, Codable {
    public var cards: [Card]
    public var adoptable: Bool

    public init(cards: [Card], adoptable: Bool) {
        self.cards = cards
        self.adoptable = adoptable
    }

    /// Reads a ticket file; one written by an older drip is a bare list of cards that is never
    /// adopted. Nil when it cannot be read.
    public static func decode(_ data: Data) -> TicketContents? {
        if let contents = try? JSONDecoder().decode(TicketContents.self, from: data) { return contents }
        return (try? JSONDecoder().decode([Card].self, from: data)).map { TicketContents(cards: $0, adoptable: false) }
    }
}

/// Decides which newer cards a drip showing a stack at the notch takes over.
public enum CardAdoption {
    /// The claim that marks the card at `index` of a ticket as adopted.
    public static func claimKey(index: Int) -> String {
        "#\(index)"
    }

    /// The cards a stack showing for the ticket `source` can adopt, oldest first: notch cards from
    /// newer, live, adoptable tickets that nobody claimed and no newer card with the same id replaced.
    public static func candidates(
        after source: String, queue: [QueueTicket], isAlive: (QueueTicket) -> Bool
    ) -> [(ticket: String, index: Int, card: Card)] {
        var found: [(ticket: String, index: Int, card: Card)] = []
        for ticket in queue.sorted(by: { $0.name < $1.name })
        where ticket.name > source && ticket.adoptable && isAlive(ticket) {
            for (index, card) in ticket.cards.enumerated()
            where card.position == .notch && !card.asksQuestion && !ticket.claimed.contains(claimKey(index: index))
                && !CardReplacement.isReplaced(card, in: ticket, queue: queue, isAlive: isAlive)
            {
                found.append((ticket.name, index, card))
            }
        }
        return found
    }
}

/// Decides which cards a newer card with the same id replaces.
public enum CardReplacement {
    /// Whether `card`, from `ticket`, should not be shown: a newer ticket whose drip is still alive
    /// has a card with the same id, or a showing drip already took this card over.
    public static func isReplaced(
        _ card: Card, in ticket: QueueTicket, queue: [QueueTicket], isAlive: (QueueTicket) -> Bool
    ) -> Bool {
        guard let id = card.id else { return false }
        if ticket.claimed.contains(id) { return true }
        return queue.contains { other in
            other.name > ticket.name && other.cards.contains { $0.id == id } && isAlive(other)
        }
    }

    /// The newest card from a ticket queued after `source` that should take the place of `showing`
    /// on screen, and the ticket it came from. Nil when there is none, or when the newest card with
    /// the same id cannot swap in place and has to wait for its own turn instead.
    public static func replacement(
        for showing: Card, after source: String, queue: [QueueTicket], isAlive: (QueueTicket) -> Bool
    ) -> (ticket: String, card: Card)? {
        guard let id = showing.id else { return nil }
        for ticket in queue.sorted(by: { $0.name > $1.name }) where ticket.name > source {
            guard !ticket.claimed.contains(id), let card = ticket.cards.last(where: { $0.id == id }),
                  isAlive(ticket)
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
