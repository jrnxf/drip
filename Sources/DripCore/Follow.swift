#if !os(WASI)
import Foundation

extension RemoteEvent {
    /// `local`, what `drip hook` reads around an event on this Mac, as it is for this event from
    /// another machine: the session's variables from the event, the machine in card ids and titles,
    /// a click that brings `activate` forward and focuses the agent's tab on `herdrMachine`, the time
    /// the event happened, never later than `local`'s, and no card when the event is `stale`.
    public func surroundings(
        _ local: AgentHook.Surroundings, activate: String?, herdrMachine: String?, stale: Bool = false
    ) -> AgentHook.Surroundings {
        var surroundings = local
        surroundings.environment = environment(over: local.environment)
        surroundings.origin = origin(activate: activate, herdrMachine: herdrMachine)
        surroundings.showsCards = local.showsCards && !stale
        surroundings.process = .follow
        surroundings.now = { [time, now = local.now] in Date(timeIntervalSince1970: min(time, now().timeIntervalSince1970)) }
        return surroundings
    }
}

/// `drip follow`: reads the queue of another machine over ssh, with `FollowReader`'s script, and
/// hands each event to `handle`, with whether it was too old when it arrived to show a card.
/// Reconnects with a growing pause when the connection drops or never comes up, and keeps its place
/// in the queue in `positionPath`, so it takes up after the last line it handled.
public final class RemoteFollower {
    public struct Settings {
        /// The machine, as ssh takes it.
        public var target: String
        /// The queue's path there; nil for `RemoteHook.defaultQueue`.
        public var queue: String?
        /// Seconds an event may be old when it arrives and still show a card.
        public var maxAge: Double
        /// The ssh program and any options of its own.
        public var ssh: [String]
        public var positionPath: String
        /// The pauses before each reconnection in a row, the last one repeating.
        public var delays: [Double]
        /// How long a connection may stay silent before it counts as dead: the reader says it is still
        /// there every `FollowReader.heartbeat` seconds.
        public var silenceLimit: Double

        public init(
            target: String, queue: String? = nil, maxAge: Double = FollowCommand.defaultMaxAge,
            ssh: [String] = ["/usr/bin/ssh"], positionPath: String, delays: [Double] = RemoteFollower.delays,
            silenceLimit: Double = 3 * FollowReader.heartbeat
        ) {
            self.target = target
            self.queue = queue
            self.maxAge = maxAge
            self.ssh = ssh
            self.positionPath = positionPath
            self.delays = delays
            self.silenceLimit = silenceLimit
        }
    }

    /// One second, doubling to a minute.
    public static let delays: [Double] = [1, 2, 4, 8, 16, 32, 60]

    /// The difference between the machine's clock and this Mac's, in seconds, that the log mentions.
    static let skewWorthSaying = 60.0

    /// How long a connection must have lasted for the next one to start over from the shortest pause.
    public static let steadyAfter = 30.0

    /// The options drip gives ssh: never a prompt, which nobody would answer, and a connection that
    /// went away noticed within a minute.
    public static let sshOptions = [
        "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3", "-o", "RemoteCommand=none",
    ]

    public var settings: Settings
    /// Shows an event's card, or only takes away what it would take away when it is stale.
    public var handle: (_ event: RemoteEvent, _ stale: Bool) -> Void
    /// Says what happens, a line at a time.
    public var log: (String) -> Void
    public var now: () -> Date = Date.init
    public var sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }

    private var stopped = false
    /// The path of the queue the machine said is missing, until it is there: said once, not on every
    /// connection.
    private var missingQueue: String?
    private var process: Process?

    public init(settings: Settings, handle: @escaping (_ event: RemoteEvent, _ stale: Bool) -> Void, log: @escaping (String) -> Void) {
        self.settings = settings
        self.handle = handle
        self.log = log
    }

    /// The command that runs the reader on the machine; the script goes on its stdin.
    public var command: [String] {
        settings.ssh + Self.sshOptions + ["--", settings.target, "sh", "-s"]
    }

    /// How often a `drip follow` waiting for the machine checks whether the one following it ended.
    public static let lockPoll = 0.5

    /// Follows the machine until `stop()`, or for `connections` connections when given. While
    /// another `drip follow` follows the same machine it waits, saying so once, and takes over
    /// when that one ends: launchd starts a follower at login whatever else runs, and a follower
    /// that exits instead is started again in a loop.
    public func run(connections: Int? = nil) throws {
        guard let lock = try acquireLock() else { return }
        defer { lock.release() }
        var attempt = 0
        var count = 0
        var lost = false
        while !stopped {
            let started = now()
            let connected = follow(reported: lost)
            count += 1
            if stopped || connections.map({ count >= $0 }) == true { return }
            if connected, now().timeIntervalSince(started) >= Self.steadyAfter { attempt = 0 }
            let delay = settings.delays[min(attempt, settings.delays.count - 1)]
            attempt += 1
            lost = true
            log("lost \(settings.target); reconnecting in \(Int(delay))s")
            sleep(delay)
        }
    }

    /// The lock that makes this the only follower of the machine, once the one holding it lets go;
    /// nil when stopped first.
    private func acquireLock() throws -> FollowLock? {
        var told = false
        while !stopped {
            if let lock = try FollowLock(path: settings.positionPath + ".lock") { return lock }
            if !told {
                log("another drip follow follows \(settings.target) already; waiting for it to end")
                told = true
            }
            Thread.sleep(forTimeInterval: Self.lockPoll)
        }
        return nil
    }

    /// Ends `run`, from `handle` or another thread.
    public func stop() {
        stopped = true
        process?.terminate()
    }

    /// One connection, until it drops. Whether the reader came up.
    private func follow(reported: Bool) -> Bool {
        signal(SIGPIPE, SIG_IGN)
        let position = FollowPosition.load(from: settings.positionPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            log("cannot run \(command[0]): \(error.localizedDescription)")
            return false
        }
        self.process = process
        defer {
            // A reader stuck writing what nobody reads any more gets an error instead, and ends.
            try? output.fileHandleForReading.close()
            Self.end(process)
            self.process = nil
        }
        try? input.fileHandleForWriting.write(contentsOf: Data(FollowReader.script(queue: settings.queue, position: position).utf8))
        try? input.fileHandleForWriting.close()

        var stream = FollowReader.Stream(position: position)
        var saved = position
        var connected = false
        var noisy = false
        var stale = 0
        // How far the machine's clock is ahead of this Mac's, from the reader's latest word of it;
        // none, when it gives no time, as when it cannot print one.
        var skew = 0.0
        var heard = now()
        let descriptor = output.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !stopped {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 1000)
            if ready < 0, errno != EINTR { break }
            if ready <= 0 {
                if now().timeIntervalSince(heard) > settings.silenceLimit {
                    log("\(settings.target) said nothing for \(Int(settings.silenceLimit))s")
                    break
                }
                continue
            }
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            heard = now()
            for (line, after) in stream.read(Array(buffer[0..<count])) {
                switch line {
                case let .hello(time):
                    connected = true
                    if reported { log("following \(settings.target) again") }
                    if let time {
                        skew = time - now().timeIntervalSince1970
                        if abs(skew) >= Self.skewWorthSaying {
                            log("\(settings.target)'s clock is \(Self.describe(abs(skew))) \(skew < 0 ? "behind" : "ahead of") this Mac's: "
                                + "its events are aged by its own clock")
                        }
                    }
                case let .heartbeat(time):
                    if let time { skew = time - now().timeIntervalSince1970 }
                    if stale > 0 {
                        log(dropped(stale))
                        stale = 0
                    }
                case .file:
                    if missingQueue != nil {
                        log("\(settings.target) has its queue now")
                        missingQueue = nil
                    }
                case let .missing(path):
                    if missingQueue != path {
                        log("\(settings.target) has no queue at \(path) yet: drip-remote-hook writes it at the agent's first event. "
                            + "If agents already ran there, check that their hooks run drip-remote-hook, and that DRIP_QUEUE or "
                            + "XDG_STATE_HOME, when set, are set where a non-interactive shell sees them, or pass --queue")
                        missingQueue = path
                    }
                case let .noise(text):
                    // Once a connection: the same banner comes with each.
                    if !noisy {
                        log("ignored what \(settings.target)'s shell printed: \(text.prefix(200))")
                        noisy = true
                    }
                case var .event(.success(event)):
                    // On this Mac's timeline, so a clock set wrong there neither makes every event
                    // stale nor later than it is; the age is the same on either.
                    event.time -= skew
                    let tooOld = event.age(now: now().timeIntervalSince1970) > settings.maxAge
                    if tooOld { stale += 1 }
                    handle(event, tooOld)
                case let .event(.failure(error)):
                    log("skipped a line of \(settings.target)'s queue: \(error)")
                }
                if let after, after != saved {
                    do {
                        try after.save(to: settings.positionPath)
                        saved = after
                    } catch {
                        log("cannot keep the place in \(settings.target)'s queue: \(error.localizedDescription)")
                    }
                }
                if stopped { break }
            }
        }
        if stale > 0 {
            log(dropped(stale))
        }
        return connected
    }

    private func dropped(_ count: Int) -> String {
        "showed no card for \(count) \(count == 1 ? "event" : "events") older than \(Self.describe(settings.maxAge)) from \(settings.target)"
    }

    /// Ends `process`: asks it to, then, after `patience` seconds, makes it.
    public static func end(_ process: Process, patience: Double = 5) {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(patience)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    /// `5m`, `1h` or `1h30m`.
    static func describe(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        let hours = minutes / 60, rest = minutes % 60
        return hours == 0 ? "\(rest)m" : rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
    }
}

/// The config file `drip follow` reads: again with each event, so an edit applies to the next,
/// with each of its warnings said once.
public final class ConfigWarnedOnce {
    private let read: ([String: String]) throws -> ConfigFile
    private let warn: (String) -> Void
    private var said: Set<String> = []

    public init(read: @escaping ([String: String]) throws -> ConfigFile, warn: @escaping (String) -> Void) {
        self.read = read
        self.warn = warn
    }

    /// The file as it is now, saying only the warnings not said before.
    public func load(environment: [String: String]) throws -> ConfigFile {
        let loaded = try read(environment)
        for warning in loaded.warnings where said.insert(warning).inserted { warn(warning) }
        return loaded
    }
}

/// An exclusive lock on a file for as long as the process holds it, so only one `drip follow`
/// follows a machine.
struct FollowLock {
    let descriptor: Int32

    /// Takes the lock on the file at `path`; nil when another process holds it.
    init?(path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StateError("cannot open \(path): \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let held = errno == EWOULDBLOCK
            let reason = String(cString: strerror(errno))
            close(descriptor)
            if held { return nil }
            throw StateError("cannot lock \(path): \(reason)")
        }
    }

    func release() {
        close(descriptor)
    }
}
#endif

#if !os(WASI)
/// The launchd agent that runs `drip follow` at login and keeps it running, as
/// `drip follow --launchd` prints it.
public enum FollowAgent {
    /// The agent's label: `co.jrnxf.drip.follow.<target>`, with anything but letters, digits, dots
    /// and hyphens in the target as hyphens.
    public static func label(target: String) -> String {
        "co.jrnxf.drip.follow." + String(target.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") ? $0 : "-" })
    }

    /// The variables of `environment` the agent keeps, besides `PATH`: drip's settings, but not
    /// `DRIP_HOOK`, which is about one session, and where drip's config and state are, so remote cards
    /// follow the settings, the config and the pause that cards from `drip hook` do.
    public static func keeps(_ name: String) -> Bool {
        (name.hasPrefix("DRIP_") && name != "DRIP_HOOK") || name == "XDG_CONFIG_HOME" || name == "XDG_STATE_HOME"
    }

    /// The agent's plist, which runs `command`. launchd starts it with almost no environment, so it
    /// gets the `PATH` of `environment`, where drip finds herdr for clicks, and the variables
    /// `keeps(_:)` names; it logs to `~/Library/Logs/<label>.log`.
    public static func plist(command: [String], target: String, environment: [String: String]) -> String {
        let label = label(target: target)
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let log = "\(home)/Library/Logs/\(label).log"
        let arguments = command.map { "        <string>\(escaped($0))</string>" }.joined(separator: "\n")
        var seen: Set<Substring> = []
        let path = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 }
            .map { $0.split(separator: ":").filter { seen.insert($0).inserted }.joined(separator: ":") }
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let kept = environment.filter { keeps($0.key) && !$0.value.isEmpty }.sorted { $0.key < $1.key }
        let variables = ([("PATH", path)] + kept.map { ($0.key, $0.value) })
            .map { "        <key>\(escaped($0.0))</key>\n        <string>\(escaped($0.1))</string>" }
            .joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(escaped(label))</string>
                <key>ProgramArguments</key>
                <array>
            \(arguments)
                </array>
                <key>EnvironmentVariables</key>
                <dict>
            \(variables)
                </dict>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>ProcessType</key>
                <string>Interactive</string>
                <key>StandardErrorPath</key>
                <string>\(escaped(log))</string>
            </dict>
            </plist>

            """
    }

    private static func escaped(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
    }
}
#endif
