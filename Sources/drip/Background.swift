#if canImport(AppKit)
import DripCore
import Foundation

/// Starts the background drip that shows cards after this one has returned.
enum BackgroundDrip {
    /// The hidden command the background drip runs.
    static let command = "__background"

    /// The longest a drip handing its stack on waits for the background drip to show it.
    static let handOffWait: Int32 = 400

    /// Starts `drip __background` with `request`, as `spawn` and `Spawned.send` do. Returns false
    /// when it cannot be started.
    static func start(_ request: BackgroundRequest) -> Bool {
        spawn(handingOff: request.handOff != nil)?.send(request) ?? false
    }

    /// Starts `drip __background` in its own session, waiting for a request on its standard input,
    /// with nothing else inherited, so it outlives this process and never holds a caller's pipe open
    /// (`out=$(drip ...)` would otherwise wait for it). One `handingOff` a stack says on its
    /// standard output when it shows the cards. A drip that asks starts one while its question
    /// shows, so the answer hands its stack on at once. Nil when it cannot be started.
    static func spawn(handingOff: Bool) -> Spawned? {
        guard let executable = Bundle.main.executablePath else { return nil }
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else { return nil }
        let (reading, writing) = (pipe[0], pipe[1])
        var shown: [Int32] = [-1, -1]
        if handingOff, Darwin.pipe(&shown) != 0 { shown = [-1, -1] }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, reading, 0)
        if shown[1] >= 0 {
            posix_spawn_file_actions_adddup2(&actions, shown[1], 1)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
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
        if shown[1] >= 0 { close(shown[1]) }
        guard spawned == 0 else {
            close(writing)
            if shown[0] >= 0 { close(shown[0]) }
            return nil
        }
        return Spawned(pid: pid, writing: writing, shown: shown[0] >= 0 ? shown[0] : nil)
    }

    /// A background drip waiting for its request. One never sent a request exits when this
    /// process does.
    final class Spawned {
        private let pid: pid_t
        private var writing: Int32?
        private let shown: Int32?

        fileprivate init(pid: pid_t, writing: Int32, shown: Int32?) {
            self.pid = pid
            self.writing = writing
            self.shown = shown
        }

        deinit {
            if let writing { close(writing) }
            if let shown { close(shown) }
        }

        /// Queues the background drip's cards and hands it `request`. A request that hands a
        /// stack on takes this drip's place in the queue, and returns once the background drip
        /// shows the cards, or after `handOffWait` milliseconds, so this drip's stack can go
        /// without the cards blinking out. Returns false when the request did not get through,
        /// and only the first request gets through.
        func send(_ request: BackgroundRequest) -> Bool {
            guard let writing, let data = try? request.encoded() else { return false }
            self.writing = nil
            CardQueue.enqueue(
                pid: pid, cards: request.cards, adoptable: true,
                after: request.handOff != nil ? CardQueue.mine?.name : nil)
            // A closed pipe must fail the write, not kill drip.
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
            if written, request.handOff != nil, let shown {
                // The background drip closing its end unsaid means it shows nothing.
                var waiting = pollfd(fd: shown, events: Int16(POLLIN), revents: 0)
                var byte: UInt8 = 0
                if poll(&waiting, 1, handOffWait) > 0, read(shown, &byte, 1) == 0 { return false }
            }
            return written
        }
    }

    /// Tells the drip that handed its stack on that the cards show here now.
    static func sayShown() {
        signal(SIGPIPE, SIG_IGN)
        var byte: UInt8 = 1
        _ = write(1, &byte, 1)
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 {
            dup2(null, 1)
            close(null)
        }
    }

    /// Reads the request a foreground drip wrote to standard input.
    static func readRequest() -> BackgroundRequest? {
        try? BackgroundRequest.decode(FileHandle.standardInput.readDataToEndOfFile())
    }
}

/// Lines cards up across every drip of this user, so they show one after another, in the order
/// the drips were run, instead of on top of each other.
///
/// Each showing drip holds a ticket: a file named for when it was queued and its pid, holding its
/// cards. The oldest ticket whose process is still alive shows; a drip that dies leaves a ticket
/// that the others skip and clean up. `CardReplacement` decides which cards a newer card with the
/// same id replaces, and `CardAdoption` which cards a drip showing a stack at the notch takes over.
enum CardQueue {
    /// The longest a drip waits for its turn before showing its cards anyway.
    static let patience: TimeInterval = 120

    /// In the user's own temporary directory, whatever `TMPDIR` says, so drips started from a shell
    /// with its own `TMPDIR` (a Nix shell, say) still line up with every other drip. `DRIP_QUEUE_DIR`,
    /// an absolute path, gives drips a queue of their own instead, as `scripts/mac-e2e.sh` does so the
    /// drip it tests never adopts, or is adopted by, the cards of every other drip on the Mac.
    private static let directory: String = {
        if let own = ProcessInfo.processInfo.environment["DRIP_QUEUE_DIR"], own.hasPrefix("/") { return own }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let base = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0
            ? String(cString: buffer) : NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent("drip-queue")
    }()

    /// This process's ticket, once it has waited for its turn.
    private(set) static var mine: QueueTicket?

    /// When this drip's cards were queued, in seconds since 1970: now, when it holds no ticket.
    static var queuedAt: Double {
        mine.flatMap { QueueTicket.queuedAt($0.name) } ?? Date().timeIntervalSince1970
    }
    /// The cards this process queues, kept for when it queues again after giving up its turn.
    private static var cards: [Card] = []
    private static var leavesAtExit = false

    /// Queues the cards of the process `pid`. A foreground drip queues its background drip itself,
    /// before returning, so the order is the order drips were run in; one that hands its stack on
    /// queues it right `after` its own ticket. Only a background drip's cards are `adoptable`.
    static func enqueue(pid: pid_t, cards: [Card], adoptable: Bool = false, after parent: String? = nil) {
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let start = HeldCards.processStartTime(pid)
        let contents = (try? JSONEncoder().encode(TicketContents(cards: cards, adoptable: adoptable))) ?? Data()
        let name = parent.flatMap { QueueTicket.name(after: $0, pid: pid, start: start) }
            ?? QueueTicket.name(stamp: stamp, pid: pid, start: start)
        write(contents, to: name)
    }

    /// Waits until every drip queued earlier has shown its cards, or until a showing drip has
    /// adopted all of this one's, queuing `cards`, or the cards it queued before when nil. Past
    /// `patience`, it waits on only while an earlier drip's question waits for its answer, which
    /// never gives way, and never longer than a question waits. The ticket goes when this process
    /// exits.
    static func waitForTurn(cards: [Card]? = nil) {
        let me = getpid()
        join(cards: cards)
        let start = Date()
        var deadline = start.addingTimeInterval(patience)
        let longest = deadline.addingTimeInterval(Defaults.waitLimit)
        while !isFirst(me), !isFullyAdopted {
            if Date() >= deadline {
                guard Date() < longest, let mine,
                      CardTurns.awaitsAnswer(before: mine.name, queue: load(), isAlive: isAlive)
                else { break }
                deadline = Date().addingTimeInterval(1)
            }
            usleep(50_000)
        }
    }

    /// Takes this process's ticket, queuing `cards`, or the cards it queued before when nil, unless
    /// it has one already, as a background drip a stack was handed on to does. The ticket goes when
    /// this process exits.
    static func join(cards: [Card]? = nil) {
        let me = getpid()
        if let cards { self.cards = cards }
        if tickets().first(where: { $0.pid == me }) == nil { enqueue(pid: me, cards: self.cards) }
        mine = tickets().first(where: { $0.pid == me })
        if !leavesAtExit {
            leavesAtExit = true
            atexit { CardQueue.leave() }
        }
    }

    /// Whether a showing drip adopted every card of this process's ticket.
    static var isFullyAdopted: Bool {
        guard let mine else { return false }
        return load().first(where: { $0.name == mine.name })?.isFullyAdopted ?? false
    }

    /// Whether a showing drip adopted the card at `index` of this process's ticket.
    static func isAdopted(index: Int) -> Bool {
        guard let mine else { return false }
        return claims(of: mine.name).contains(CardAdoption.claimKey(index: index))
    }

    /// The newer cards a stack showing for this process's ticket can adopt, oldest first.
    static func adoptable() -> [(ticket: String, index: Int, card: Card)] {
        guard let mine else { return [] }
        return CardAdoption.candidates(after: mine.name, queue: load(), isAlive: isAlive)
    }

    /// Marks the card at `index` of `ticket` as adopted, so its own drip skips it.
    static func adopt(index: Int, in ticket: String) {
        claim(CardAdoption.claimKey(index: index), in: ticket)
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

    /// The cards of newer drips still waiting for their turn, leaving out those with an id in
    /// `except`, which take the place of a card on screen instead; and whether a stack could adopt each.
    static func waiting(except ids: Set<String>) -> [(card: Card, adoptable: Bool)] {
        guard let mine else { return [] }
        return CardTurns.waiting(after: mine.name, queue: load(), isAlive: isAlive, except: ids)
    }

    /// Marks the card with `id` in `ticket` as taken over, so its own drip skips it.
    static func claim(_ id: String, in ticket: String) {
        var claimed = claims(of: ticket)
        claimed.insert(id)
        write((try? JSONEncoder().encode(claimed.sorted())) ?? Data(), to: QueueTicket.claimName(for: ticket))
    }

    /// Whether `pid` holds the oldest live ticket, clearing the tickets of drips that died.
    private static func isFirst(_ pid: pid_t) -> Bool {
        for ticket in tickets() {
            if ticket.pid == pid { return true }
            if isAlive(ticket) { return false }
            remove(ticket.name)
        }
        // The ticket is gone, so there is nothing left to wait for.
        return true
    }

    /// Whether the drip that queued `ticket` still runs: its pid is alive and, when the ticket says
    /// when it started, started then. A drip killed before it could remove its ticket leaves one
    /// whose pid another process may get, which would otherwise hold up every card for `patience`.
    /// Every ticket is this user's, so a pid that cannot be signaled is not a drip.
    private static func isAlive(_ ticket: QueueTicket) -> Bool {
        guard let start = ticket.start else { return kill(ticket.pid, 0) == 0 }
        return HeldCards.processStartTime(ticket.pid) == start
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
            if let data = FileManager.default.contents(atPath: path(ticket.name)), !data.isEmpty,
               let contents = TicketContents.decode(data)
            {
                ticket.cards = contents.cards
                ticket.adoptable = contents.adoptable
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

    /// Gives up this process's turn, for a drip that waits for something else before showing.
    static func leave() {
        let me = getpid()
        tickets().filter { $0.pid == me }.forEach { remove($0.name) }
    }
}
#endif

