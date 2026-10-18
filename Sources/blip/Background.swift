#if canImport(AppKit)
import BlipCore
import Foundation

/// Starts the background blip that shows cards after this one has returned.
enum BackgroundBlip {
    /// The hidden command the background blip runs.
    static let command = "__background"

    /// Starts `blip __background` in its own session, with the request on its standard input and
    /// nothing else inherited, so it outlives this process and never holds a caller's pipe open
    /// (`out=$(blip ...)` would otherwise wait for it). Returns false when it cannot be started.
    static func start(_ request: BackgroundRequest) -> Bool {
        guard let data = try? request.encoded(), let executable = Bundle.main.executablePath else { return false }
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else { return false }
        let (reading, writing) = (pipe[0], pipe[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, reading, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        // Its own session: Ctrl-C or closing the terminal doesn't take the card with it. Every
        // descriptor not set up above is closed in the child.
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup(command), nil]
        defer { arguments.forEach { free($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { environment.forEach { free($0) } }

        var pid = pid_t()
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, &arguments, &environment)
        close(reading)
        guard spawned == 0 else {
            close(writing)
            return false
        }
        CardQueue.enqueue(pid: pid, cards: request.cards)
        // A closed pipe must fail the write, not kill blip.
        signal(SIGPIPE, SIG_IGN)
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(writing, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        close(writing)
        return written
    }

    /// Reads the request a foreground blip wrote to standard input.
    static func readRequest() -> BackgroundRequest? {
        try? BackgroundRequest.decode(FileHandle.standardInput.readDataToEndOfFile())
    }
}

/// Lines cards up across every blip of this user, so they show one after another, in the order
/// the blips were run, instead of on top of each other.
///
/// Each showing blip holds a ticket: a file named for when it was queued and its pid, holding its
/// cards that carry an id. The oldest ticket whose process is still alive shows; a blip that dies
/// leaves a ticket that the others skip and clean up. `CardReplacement` decides which cards a
/// newer card with the same id replaces.
enum CardQueue {
    /// The longest a blip waits for its turn before showing its cards anyway.
    static let patience: TimeInterval = 120

    private static let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("blip-queue")

    /// This process's ticket, once it has waited for its turn.
    private(set) static var mine: QueueTicket?
    /// The cards this process queues, kept for when it queues again after giving up its turn.
    private static var cards: [Card] = []
    private static var leavesAtExit = false

    /// Queues the cards of the process `pid`. A foreground blip queues its background blip itself,
    /// before returning, so the order is the order blips were run in.
    static func enqueue(pid: pid_t, cards: [Card]) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let stamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let replaceable = cards.filter { $0.id != nil }
        let contents = replaceable.isEmpty ? Data() : (try? JSONEncoder().encode(replaceable)) ?? Data()
        write(contents, to: QueueTicket.name(stamp: stamp, pid: pid))
    }

    /// Waits until every blip queued earlier has shown its cards, queuing `cards`, or the cards it
    /// queued before when nil. The ticket goes when this process exits.
    static func waitForTurn(cards: [Card]? = nil) {
        let me = getpid()
        if let cards { self.cards = cards }
        if tickets().first(where: { $0.pid == me }) == nil { enqueue(pid: me, cards: self.cards) }
        mine = tickets().first(where: { $0.pid == me })
        if !leavesAtExit {
            leavesAtExit = true
            atexit { CardQueue.leave() }
        }
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline, !isFirst(me) {
            usleep(50_000)
        }
    }

    /// Whether a newer card with the same id has replaced `card`, so it should not be shown.
    static func isReplaced(_ card: Card) -> Bool {
        guard card.id != nil, let mine else { return false }
        let queue = load()
        let ticket = queue.first(where: { $0.name == mine.name }) ?? mine
        return CardReplacement.isReplaced(card, in: ticket, queue: queue, isAlive: isAlive)
    }

    /// The newest card queued after `source` that should take the place of `showing` on screen,
    /// and its ticket.
    static func replacement(for showing: Card, after source: String) -> (ticket: String, card: Card)? {
        guard showing.id != nil else { return nil }
        return CardReplacement.replacement(for: showing, after: source, queue: load(), isAlive: isAlive)
    }

    /// Marks the card with `id` in `ticket` as taken over, so its own blip skips it.
    static func claim(_ id: String, in ticket: String) {
        var claimed = claims(of: ticket)
        claimed.insert(id)
        write((try? JSONEncoder().encode(claimed.sorted())) ?? Data(), to: QueueTicket.claimName(for: ticket))
    }

    /// Whether `pid` holds the oldest live ticket, clearing the tickets of blips that died.
    private static func isFirst(_ pid: pid_t) -> Bool {
        for ticket in tickets() {
            if ticket.pid == pid { return true }
            if isAlive(ticket.pid) { return false }
            remove(ticket.name)
        }
        // The ticket is gone, so there is nothing left to wait for.
        return true
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    /// The tickets in queue order, without reading them.
    private static func tickets() -> [QueueTicket] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.sorted().compactMap { QueueTicket(name: $0) }
    }

    /// The tickets in queue order, with their cards and claims.
    private static func load() -> [QueueTicket] {
        tickets().map { ticket in
            var ticket = ticket
            if let data = FileManager.default.contents(atPath: path(ticket.name)), !data.isEmpty {
                ticket.cards = (try? JSONDecoder().decode([Card].self, from: data)) ?? []
            }
            ticket.claimed = claims(of: ticket.name)
            return ticket
        }
    }

    private static func claims(of ticket: String) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: path(QueueTicket.claimName(for: ticket))) else { return [] }
        return Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }

    /// Writes a file whole, so a reader never sees it half written: to a hidden name first, which
    /// is not a ticket, then renamed into place.
    private static func write(_ contents: Data, to name: String) {
        let temporary = path(".\(name).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: temporary, contents: contents) else { return }
        if rename(temporary, path(name)) != 0 { try? FileManager.default.removeItem(atPath: temporary) }
    }

    private static func path(_ name: String) -> String {
        (directory as NSString).appendingPathComponent(name)
    }

    private static func remove(_ ticket: String) {
        try? FileManager.default.removeItem(atPath: path(ticket))
        try? FileManager.default.removeItem(atPath: path(QueueTicket.claimName(for: ticket)))
    }

    /// Gives up this process's turn, for a blip that waits for something else before showing.
    static func leave() {
        let me = getpid()
        tickets().filter { $0.pid == me }.forEach { remove($0.name) }
    }
}
#endif
