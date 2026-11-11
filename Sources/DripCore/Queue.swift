#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif

/// One drip's place in the queue that shows cards one after another across every drip of a user.
///
/// A ticket is a file named for when it was queued, the pid that shows its cards and when that
/// process started, so a later process given the same pid is not taken for it. It holds the
/// cards, so a newer drip's card can replace them and a showing drip can adopt them into its stack.
/// When a showing drip takes over a newer ticket's card on screen, it marks that card as claimed,
/// by its id or by its place in the ticket, and the newer drip then skips it. It claims the id in
/// every older ticket that holds a card with it too, so those cards stay replaced once the newer
/// drip has gone.
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
    /// Whether its drip prints how its card ended, as `drip --result` does: no other drip may take
    /// the card over, so the card shows in this drip's own turn, as a question does.
    public var reportsResult: Bool

    /// Parses a ticket file name: a 20-digit timestamp, a hyphen and a pid, then a hyphen and the
    /// process's start time when it was known. Nil for anything else, such as a claim file or a
    /// ticket still being written.
    public init?(
        name: String, cards: [Card] = [], claimed: Set<String> = [], adoptable: Bool = false,
        reportsResult: Bool = false
    ) {
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
        self.reportsResult = reportsResult
    }

    /// The file name for a ticket queued at `stamp` nanoseconds since 1970. Names sort in the
    /// order the tickets were queued.
    public static func name(stamp: UInt64, pid: Int32, start: UInt64? = nil) -> String {
        let digits = String(stamp)
        return String(repeating: "0", count: max(20 - digits.count, 0)) + digits + "-\(pid)"
            + (start.map { "-\($0)" } ?? "")
    }

    /// The file name for a ticket that takes `parent`'s place in the queue: queued a nanosecond after
    /// it, so it sorts right after it and before every ticket queued later. Nil when `parent` is not
    /// a ticket.
    public static func name(after parent: String, pid: Int32, start: UInt64? = nil) -> String? {
        guard QueueTicket(name: parent) != nil, let stamp = UInt64(parent.prefix(20)) else { return nil }
        return name(stamp: stamp + 1, pid: pid, start: start)
    }

    /// When a ticket with this name was queued, in seconds since 1970; nil when it is not a ticket.
    public static func queuedAt(_ name: String) -> Double? {
        guard QueueTicket(name: name) != nil, let stamp = UInt64(name.prefix(20)) else { return nil }
        return Double(stamp) / 1_000_000_000
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
    /// See `QueueTicket.reportsResult`.
    public var reportsResult: Bool

    public init(cards: [Card], adoptable: Bool, reportsResult: Bool = false) {
        self.cards = cards
        self.adoptable = adoptable
        self.reportsResult = reportsResult
    }

    private enum CodingKeys: String, CodingKey {
        case cards, adoptable, reportsResult
    }

    /// A ticket an older drip wrote has no `reportsResult`: its drip reports nothing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cards = try container.decode([Card].self, forKey: .cards)
        adoptable = try container.decode(Bool.self, forKey: .adoptable)
        reportsResult = try container.decodeIfPresent(Bool.self, forKey: .reportsResult) ?? false
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

    /// The cards a stack showing for the ticket `source` can adopt, oldest first: cards from newer,
    /// live, adoptable tickets that nobody claimed and no newer card with the same id replaced. A
    /// card whose drip prints how it ended is never one: only its own drip sees how it ends.
    public static func candidates(
        after source: String, queue: [QueueTicket], isAlive: (QueueTicket) -> Bool
    ) -> [(ticket: String, index: Int, card: Card)] {
        var found: [(ticket: String, index: Int, card: Card)] = []
        for ticket in queue.sorted(by: { $0.name < $1.name })
        where ticket.name > source && ticket.adoptable && !ticket.reportsResult && isAlive(ticket) {
            for (index, card) in ticket.cards.enumerated()
            where !card.asksQuestion && !ticket.claimed.contains(claimKey(index: index))
                && !CardReplacement.isReplaced(card, in: ticket, queue: queue, isAlive: isAlive)
            {
                found.append((ticket.name, index, card))
            }
        }
        return found
    }
}

/// Tells a card that waits for you whether a newer drip's card is waiting for its turn, so it can
/// give way.
public enum CardTurns {
    /// The cards of live drips queued after `source` that still wait for their turn: not adopted,
    /// claimed or replaced, and without an id in `except`, as such a card takes the place of a card
    /// on screen instead. A question, or a card whose drip prints how it ended, never takes another's
    /// place, so it waits whatever its id. `adoptable` says whether a stack at the notch could take
    /// the card in.
    public static func waiting(
        after source: String, queue: [QueueTicket], isAlive: (QueueTicket) -> Bool, except ids: Set<String> = []
    ) -> [(card: Card, adoptable: Bool)] {
        var found: [(card: Card, adoptable: Bool)] = []
        for ticket in queue.sorted(by: { $0.name < $1.name }) where ticket.name > source && isAlive(ticket) {
            for (index, card) in ticket.cards.enumerated()
            where !ticket.claimed.contains(CardAdoption.claimKey(index: index))
                && (ticket.reportsResult || card.asksQuestion || !(card.id.map(ids.contains) ?? false))
                && !CardReplacement.isReplaced(card, in: ticket, queue: queue, isAlive: isAlive)
            {
                found.append((card, ticket.adoptable && !card.asksQuestion))
            }
        }
        return found
    }

    /// Whether the cards that wait for you on screen give way: a newer drip's card waits for its turn
    /// that the drip showing them does not take in. A stack that `adopts` takes in every adoptable
    /// card itself, so only the others count. For any other drip every card waiting counts. Cards
    /// with an id in `except` take the place of a card on screen instead, as for `waiting`.
    public static func othersWait(
        after source: String, queue: [QueueTicket], isAlive: (QueueTicket) -> Bool, except ids: Set<String> = [],
        adopts: Bool
    ) -> Bool {
        waiting(after: source, queue: queue, isAlive: isAlive, except: ids).contains { !adopts || !$0.adoptable }
    }

    /// Whether a live drip queued before `source` shows, or will show, a question that waits for its
    /// answer: a drip waiting for its turn then waits on, past its usual patience, as the question
    /// never gives way.
    public static func awaitsAnswer(
        before source: String, queue: [QueueTicket], isAlive: (QueueTicket) -> Bool
    ) -> Bool {
        queue.contains { ticket in
            ticket.name < source && ticket.cards.contains(where: \.waitsForAnswer) && isAlive(ticket)
        }
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
    /// the same id cannot swap in place and has to wait for its own turn instead: a question, or a
    /// card whose drip prints how it ended.
    public static func replacement(
        for showing: Card, after source: String, queue: [QueueTicket], isAlive: (QueueTicket) -> Bool
    ) -> (ticket: String, card: Card)? {
        guard let id = showing.id else { return nil }
        for ticket in queue.sorted(by: { $0.name > $1.name }) where ticket.name > source {
            guard !ticket.claimed.contains(id), let card = ticket.cards.last(where: { $0.id == id }),
                  isAlive(ticket)
            else { continue }
            return canSwap(showing, for: card) && !ticket.reportsResult ? (ticket.name, card) : nil
        }
        return nil
    }

    /// The live tickets queued before `newer` that hold a card with `id` not yet claimed. Once a
    /// showing drip takes over `newer`'s card with that id, those cards are replaced for good. The
    /// newer drip exits soon after, as it has nothing left to show, and its ticket goes with it. So
    /// each of these tickets needs the id claimed to stay replaced.
    public static func superseded(
        id: String, by newer: String, queue: [QueueTicket], isAlive: (QueueTicket) -> Bool
    ) -> [String] {
        queue.filter { ticket in
            ticket.name < newer && !ticket.claimed.contains(id) && ticket.cards.contains { $0.id == id }
                && isAlive(ticket)
        }.map(\.name).sorted()
    }

    /// The cards in order, keeping only the newest card for each id; cards without an id all stay.
    public static func latest(_ cards: [Card]) -> [Card] {
        cards.indices.filter { index in
            guard let id = cards[index].id else { return true }
            return !cards[(index + 1)...].contains { $0.id == id }
        }.map { cards[$0] }
    }

    /// Whether `new` can take the place of `old` on screen. A card that asks a question reports its
    /// click to the drip that showed it, so it never swaps.
    public static func canSwap(_ old: Card, for new: Card) -> Bool {
        !old.asksQuestion && !new.asksQuestion
    }
}
