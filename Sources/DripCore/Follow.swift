#if !os(WASI)
import Foundation

extension RemoteEvent {
    /// `local`, what `drip hook` reads around an event on this Mac, as it is for this event from
    /// another machine: the session's variables from the event, the machine in card ids and titles,
    /// and a click that brings `activate` forward and focuses the agent's tab on `herdrMachine`.
    public func surroundings(
        _ local: AgentHook.Surroundings, activate: String?, herdrMachine: String?
    ) -> AgentHook.Surroundings {
        var surroundings = local
        surroundings.environment = environment(over: local.environment)
        surroundings.origin = origin(activate: activate, herdrMachine: herdrMachine)
        return surroundings
    }
}

/// `drip follow`: reads the queue of another machine over ssh, with `FollowReader`'s script, and
/// hands each event young enough to `handle`. Reconnects with a growing pause when the connection
/// drops or never comes up, and keeps its place in the queue in `positionPath`, so it takes up after
/// the last line it handled.
public final class RemoteFollower {
    public struct Settings {
        /// The machine, as ssh takes it.
        public var target: String
        /// The queue's path there; nil for `RemoteHook.defaultQueue`.
        public var queue: String?
        /// Seconds an event may be old when it arrives.
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

    /// How long a connection must have lasted for the next one to start over from the shortest pause.
    public static let steadyAfter = 30.0

    /// The options drip gives ssh: never a prompt, which nobody would answer, and a connection that
    /// went away noticed within a minute.
    public static let sshOptions = [
        "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
    ]

    public var settings: Settings
    /// Shows an event's card.
    public var handle: (RemoteEvent) -> Void
    /// Says what happens, a line at a time.
    public var log: (String) -> Void
    public var now: () -> Date = Date.init
    public var sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }

    private var stopped = false
    private var process: Process?

    public init(settings: Settings, handle: @escaping (RemoteEvent) -> Void, log: @escaping (String) -> Void) {
        self.settings = settings
        self.handle = handle
        self.log = log
    }

    /// The command that runs the reader on the machine; the script goes on its stdin.
    public var command: [String] {
        settings.ssh + Self.sshOptions + ["--", settings.target, "sh", "-s"]
    }

    /// Follows the machine until `stop()`, or for `connections` connections when given. Throws a
    /// `StateError` when another `drip follow` follows the same machine.
    public func run(connections: Int? = nil) throws {
        let lock = try FollowLock(path: settings.positionPath + ".lock")
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
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            self.process = nil
        }
        try? input.fileHandleForWriting.write(contentsOf: Data(FollowReader.script(queue: settings.queue, position: position).utf8))
        try? input.fileHandleForWriting.close()

        var stream = FollowReader.Stream(position: position)
        var saved = position
        var connected = false
        var stale = 0
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
                case .hello:
                    connected = true
                    if reported { log("following \(settings.target) again") }
                case .heartbeat:
                    if stale > 0 {
                        log(dropped(stale))
                        stale = 0
                    }
                case .file:
                    break
                case let .event(.success(event)):
                    if event.age(now: now().timeIntervalSince1970) > settings.maxAge {
                        stale += 1
                    } else {
                        handle(event)
                    }
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
        "dropped \(count) \(count == 1 ? "event" : "events") older than \(Self.describe(settings.maxAge)) from \(settings.target)"
    }

    /// `5m`, `1h` or `1h30m`.
    static func describe(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        let hours = minutes / 60, rest = minutes % 60
        return hours == 0 ? "\(rest)m" : rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
    }
}

/// An exclusive lock on a file for as long as the process holds it, so only one `drip follow`
/// follows a machine.
struct FollowLock {
    let descriptor: Int32

    init(path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StateError("cannot open \(path): \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw StateError("another drip follow follows this machine already")
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

    /// The agent's plist, which runs `command`. launchd starts it with almost no `PATH`, so it gets
    /// the `PATH` of `environment`, where drip finds herdr for clicks; it logs to
    /// `~/Library/Logs/<label>.log`.
    public static func plist(command: [String], target: String, environment: [String: String]) -> String {
        let label = label(target: target)
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let log = "\(home)/Library/Logs/\(label).log"
        let arguments = command.map { "        <string>\(escaped($0))</string>" }.joined(separator: "\n")
        var seen: Set<Substring> = []
        let path = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 }
            .map { $0.split(separator: ":").filter { seen.insert($0).inserted }.joined(separator: ":") }
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
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
                    <key>PATH</key>
                    <string>\(escaped(path))</string>
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
