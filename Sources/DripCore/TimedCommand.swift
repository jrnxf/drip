#if !os(WASI) // Spawns processes, which WebAssembly cannot.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Runs a short command for what it prints, as drip asks a terminal's command line which pane shows,
/// with a deadline that holds: a command that hangs, or leaves a process behind holding its output
/// open, holds drip, a click or `drip follow`'s next card up for its timeout and a short grace at most.
public enum TimedCommand {
    /// Why a command did not answer: what it wrote to stderr, and how it ended.
    public struct Failure: Error, Equatable {
        public var stderr: String
        public var reason: String

        public init(stderr: String, reason: String) {
            self.stderr = stderr
            self.reason = reason
        }
    }

    /// How long a command that did not answer in time has to end once asked, before it is made to.
    public static let grace = 0.5

    /// What `arguments`, a program found on `PATH` and its arguments, after any `NAME=value` for its
    /// environment, prints, when it exits 0 and closes its output within `timeout` seconds; else why
    /// not. A command still going then gets SIGTERM, with the processes it started, and SIGKILL
    /// `grace` seconds later, and does not answer even when it exits 0 meanwhile. Its stdout and
    /// stderr are read together, so one it fills never holds it up.
    public static func run(_ arguments: [String], timeout: Double, grace: Double = grace) -> Result<String, Failure> {
        var output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1]
        guard pipe(&output) == 0 else { return .failure(Failure(stderr: "", reason: String(cString: strerror(errno)))) }
        guard pipe(&errors) == 0 else {
            let reason = String(cString: strerror(errno))
            output.forEach { close($0) }
            return .failure(Failure(stderr: "", reason: reason))
        }
        // Only the command gets them: no other program drip starts keeps them open.
        for descriptor in output + errors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        let (pid, spawned) = spawn(arguments, output: output[1], errors: errors[1])
        close(output[1])
        close(errors[1])
        guard spawned == 0 else {
            close(output[0])
            close(errors[0])
            return .failure(Failure(stderr: "", reason: String(cString: strerror(spawned))))
        }

        let clock = ProcessInfo.processInfo
        var deadline = clock.systemUptime + timeout
        var open = [output[0], errors[0]]
        var said: [Int32: [UInt8]] = [output[0]: [], errors[0]: []]
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // Set once the command is reaped, which it is only before the deadline: until then its process
        // group cannot be another's, so signalling it reaches nothing else.
        var status: Int32?
        var timedOut = false
        var problem: String?
        while status == nil || !open.isEmpty {
            let left = deadline - clock.systemUptime
            if left <= 0 {
                if timedOut { break }
                timedOut = true
                kill(-pid, SIGTERM)
                deadline = clock.systemUptime + grace
                continue
            }
            if open.isEmpty {
                // It has closed its output; once asked to end, that is enough.
                if timedOut { break }
                var code: Int32 = 0
                let reaped = waitpid(pid, &code, WNOHANG)
                if reaped == pid || (reaped == -1 && errno != EINTR) {
                    status = reaped == pid ? code : -1
                } else {
                    usleep(UInt32(min(left, 0.005) * 1_000_000))
                }
                continue
            }
            var polled = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&polled, nfds_t(polled.count), Int32((left * 1000).rounded(.up)))
            if ready < 0, errno != EINTR {
                problem = String(cString: strerror(errno))
                break
            }
            for item in polled where item.revents != 0 {
                let count = read(item.fd, &buffer, buffer.count)
                if count > 0 {
                    said[item.fd, default: []].append(contentsOf: buffer[0..<count])
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    close(item.fd)
                    open.removeAll { $0 == item.fd }
                }
            }
        }
        open.forEach { close($0) }
        let stderr = String(decoding: said[errors[0]] ?? [], as: UTF8.self)
        guard let status else {
            kill(-pid, SIGKILL)
            // In case it left its group.
            kill(pid, SIGKILL)
            DispatchQueue.global().async {
                var code: Int32 = 0
                while waitpid(pid, &code, 0) == -1, errno == EINTR {}
            }
            return .failure(Failure(stderr: stderr, reason: timedOut ? "no answer within \(describe(timeout))" : problem ?? "lost track of it"))
        }
        // The W* macros are not available in Swift: the low 7 bits hold the signal, if any.
        let signal = status & 0x7F, code = (status >> 8) & 0xFF
        guard status != -1, signal == 0, code == 0 else {
            let reason = status == -1 ? "lost track of it" : signal == 0 ? "exit status \(code)" : "killed by signal \(signal)"
            return .failure(Failure(stderr: stderr, reason: reason))
        }
        return .success(String(decoding: said[output[0]] ?? [], as: UTF8.self))
    }

    /// `1s`, or `0.5s`.
    static func describe(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds))s" : "\(seconds)s"
    }

    /// Starts `/usr/bin/env` with `arguments`, its stdin from /dev/null and its stdout and stderr to
    /// `output` and `errors`, in a process group of its own, with every signal handled the default way
    /// and none blocked. The pid, and 0 or why it could not start.
    private static func spawn(_ arguments: [String], output: Int32, errors: Int32) -> (pid_t, Int32) {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, errors, 2)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        var flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        #if canImport(Darwin)
        // Nothing else drip has open.
        flags |= POSIX_SPAWN_CLOEXEC_DEFAULT
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let program = "/usr/bin/env"
        var argv: [UnsafeMutablePointer<CChar>?] = ([program] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        // Built from ProcessInfo because Darwin does not expose `environ` to Swift.
        var environment: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { environment.forEach { free($0) } }
        var pid = pid_t()
        let spawned = posix_spawn(&pid, program, &actions, &attributes, &argv, &environment)
        return (pid, spawned)
    }
}
#endif
