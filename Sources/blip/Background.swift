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
        CardQueue.enqueue(pid: pid)
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
/// Each showing blip holds a ticket: an empty file named for when it was queued and its pid. The
/// oldest ticket whose process is still alive shows; a blip that dies leaves a ticket that the
/// others skip and clean up.
enum CardQueue {
    /// The longest a blip waits for its turn before showing its cards anyway.
    static let patience: TimeInterval = 120

    private static let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("blip-queue")

    /// Queues the cards of the process `pid`. A foreground blip queues its background blip itself,
    /// before returning, so the order is the order blips were run in.
    static func enqueue(pid: pid_t) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let stamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let name = String(format: "%020llu-%d", stamp, pid)
        FileManager.default.createFile(atPath: (directory as NSString).appendingPathComponent(name), contents: nil)
    }

    /// Waits until every blip queued earlier has shown its cards. The ticket goes when this
    /// process exits.
    static func waitForTurn() {
        let me = getpid()
        if tickets().first(where: { $0.pid == me }) == nil { enqueue(pid: me) }
        atexit { CardQueue.leave() }
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline, !isFirst(me) {
            usleep(50_000)
        }
    }

    /// Whether `pid` holds the oldest live ticket, clearing the tickets of blips that died.
    private static func isFirst(_ pid: pid_t) -> Bool {
        for ticket in tickets() {
            if ticket.pid == pid { return true }
            if kill(ticket.pid, 0) == 0 || errno != ESRCH { return false }
            remove(ticket)
        }
        // The ticket is gone, so there is nothing left to wait for.
        return true
    }

    private struct Ticket {
        var name: String
        var pid: pid_t
    }

    private static func tickets() -> [Ticket] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.sorted().compactMap { name in
            guard let pid = name.split(separator: "-").last.flatMap({ pid_t($0) }) else { return nil }
            return Ticket(name: name, pid: pid)
        }
    }

    private static func remove(_ ticket: Ticket) {
        try? FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent(ticket.name))
    }

    private static func leave() {
        let me = getpid()
        tickets().filter { $0.pid == me }.forEach { remove($0) }
    }
}
#endif
