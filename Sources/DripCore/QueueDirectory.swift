#if !os(WASI)
import Foundation

/// The directory of tickets that lines drips up across every drip of a user: enqueue, find the
/// oldest live ticket, claim cards, leave. The app's `CardQueue` points it at the user's temporary
/// directory with the real liveness check; tests point it at a directory of their own and decide
/// who is alive.
public struct QueueDirectory {
    public var path: String
    /// Whether the drip that queued a ticket still runs.
    public var isAlive: (QueueTicket) -> Bool
    /// When a process started; replaceable so tests can stand in for other drips.
    public var processStart: (Int32) -> UInt64?

    public init(
        path: String,
        isAlive: @escaping (QueueTicket) -> Bool,
        processStart: @escaping (Int32) -> UInt64? = HeldCards.processStartTime
    ) {
        self.path = path
        self.isAlive = isAlive
        self.processStart = processStart
    }

    /// Queues the cards of the process `pid` and returns its ticket's name. A foreground drip
    /// queues its background drip itself, before returning, so the order is the order drips were
    /// run in; one that hands its stack on queues it right `after` its own ticket. Only a
    /// background drip's cards are `adoptable`. `stamp` is when it was queued, in nanoseconds
    /// since 1970.
    @discardableResult
    public func enqueue(
        pid: Int32, cards: [Card], adoptable: Bool = false, after parent: String? = nil,
        stamp: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    ) -> String {
        try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let start = processStart(pid)
        let contents = (try? JSONEncoder().encode(TicketContents(cards: cards, adoptable: adoptable))) ?? Data()
        let name = parent.flatMap { QueueTicket.name(after: $0, pid: pid, start: start) }
            ?? QueueTicket.name(stamp: stamp, pid: pid, start: start)
        write(contents, to: name, writer: pid)
        return name
    }

    /// The ticket of the process `pid`, if it holds one. A ticket whose pid matches but whose
    /// process started at another time belongs to a drip that died and left its pid to this one.
    public func ticket(of pid: Int32) -> QueueTicket? {
        let start = processStart(pid)
        return tickets().first { isHeld($0, by: pid, started: start) }
    }

    /// Whether `pid` holds the oldest live ticket, clearing the tickets of drips that died.
    public func isFirst(_ pid: Int32) -> Bool {
        let start = processStart(pid)
        for ticket in tickets() {
            if isHeld(ticket, by: pid, started: start) { return true }
            if isAlive(ticket) { return false }
            remove(ticket.name)
        }
        // The ticket is gone, so there is nothing left to wait for.
        return true
    }

    /// The tickets in queue order, without reading them.
    public func tickets() -> [QueueTicket] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.sorted().compactMap { QueueTicket(name: $0) }
    }

    /// The tickets in queue order, with their cards and claims.
    public func load() -> [QueueTicket] {
        tickets().map { ticket in
            var ticket = ticket
            if let data = FileManager.default.contents(atPath: file(ticket.name)), !data.isEmpty,
               let contents = TicketContents.decode(data)
            {
                ticket.cards = contents.cards
                ticket.adoptable = contents.adoptable
            }
            ticket.claimed = claims(of: ticket.name)
            return ticket
        }
    }

    public func claims(of ticket: String) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: file(QueueTicket.claimName(for: ticket))) else { return [] }
        return Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }

    /// Marks the card with `id` in `ticket` as taken over, so its own drip skips it.
    public func claim(_ id: String, in ticket: String) {
        var claimed = claims(of: ticket)
        claimed.insert(id)
        write((try? JSONEncoder().encode(claimed.sorted())) ?? Data(), to: QueueTicket.claimName(for: ticket), writer: getpid())
    }

    public func remove(_ ticket: String) {
        try? FileManager.default.removeItem(atPath: file(ticket))
        try? FileManager.default.removeItem(atPath: file(QueueTicket.claimName(for: ticket)))
    }

    /// Gives up the turn of the process `pid`.
    public func leave(_ pid: Int32) {
        let start = processStart(pid)
        tickets().filter { isHeld($0, by: pid, started: start) }.forEach { remove($0.name) }
    }

    /// Whether `ticket` is the one of the process `pid`, which started at `start`. A ticket that
    /// does not say when its process started, as one queued for a process already gone does, is
    /// matched by pid alone.
    private func isHeld(_ ticket: QueueTicket, by pid: Int32, started start: UInt64?) -> Bool {
        ticket.pid == pid && (ticket.start == nil || ticket.start == start)
    }

    /// Writes a file whole, so a reader never sees it half written: to a hidden name first, which
    /// is not a ticket, then renamed into place.
    private func write(_ contents: Data, to name: String, writer: Int32) {
        let temporary = file(".\(name).\(writer).tmp")
        guard FileManager.default.createFile(atPath: temporary, contents: contents) else { return }
        if rename(temporary, file(name)) != 0 { try? FileManager.default.removeItem(atPath: temporary) }
    }

    private func file(_ name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }
}
#endif
