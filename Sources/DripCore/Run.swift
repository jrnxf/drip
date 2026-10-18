#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The card `drip run` shows for a finished command.
public enum RunSummary {
    /// `<command> finished`, or `<command> failed (exit N)`. Only the command part is truncated,
    /// so the outcome always fits in the title.
    public static func title(command: [String], status: Int32) -> String {
        let suffix = status == 0 ? " finished" : " failed (exit \(status))"
        let commandLine = CardText.normalize(command.joined(separator: " "))
        return CardText.truncate(commandLine, limit: Defaults.runTitleLimit - suffix.count) + suffix
    }

    /// A wall time such as `3.1s`, `42s`, `3m 12s` or `1h 4m 0s`.
    public static func duration(seconds: Double) -> String {
        if seconds < 10 {
            let tenths = (max(seconds, 0) * 10).rounded(.down) / 10
            return "\(tenths)s"
        }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let remainder = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(remainder)s" }
        if minutes > 0 { return "\(minutes)m \(remainder)s" }
        return "\(remainder)s"
    }
}

/// Runs a command with drip's own stdin, stdout and stderr.
public enum CommandRunner {
    public struct Outcome: Equatable {
        /// The exit code to report: the command's own, 128 plus the signal that ended it, 127 when
        /// it was not found, or 126 when it could not be started.
        public var status: Int32
        /// Why the command could not be started, if it could not.
        public var error: String?
    }

    /// Runs `command`, looking it up on PATH, and waits for it to finish.
    ///
    /// Like a shell running a foreground job, drip ignores SIGINT and SIGQUIT while the command
    /// runs, so Ctrl-C stops the command and drip still reports how it ended. The command gets
    /// the default handlers back, and no blocked signals whatever thread spawns it.
    public static func run(_ command: [String]) -> Outcome {
        precondition(!command.isEmpty, "the command must not be empty")

        let previousInterrupt = signal(SIGINT, SIG_IGN)
        let previousQuit = signal(SIGQUIT, SIG_IGN)
        defer {
            signal(SIGINT, previousInterrupt)
            signal(SIGQUIT, previousQuit)
        }

        #if canImport(Darwin)
        var attributes: posix_spawnattr_t?
        #else
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGQUIT)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var arguments: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        // Built from ProcessInfo because Darwin does not expose `environ` to Swift.
        var environment: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { environment.forEach { free($0) } }

        var pid = pid_t()
        let spawned = posix_spawnp(&pid, command[0], nil, &attributes, &arguments, &environment)
        guard spawned == 0 else {
            let reason = spawned == ENOENT ? "command not found" : String(cString: strerror(spawned))
            return Outcome(status: spawned == ENOENT ? 127 : 126, error: "\(command[0]): \(reason)")
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return Outcome(status: 1, error: "waitpid failed") }
        }
        // The W* macros are not available in Swift: the low 7 bits hold the signal, if any.
        let terminatingSignal = status & 0x7F
        return Outcome(
            status: terminatingSignal == 0 ? (status >> 8) & 0xFF : 128 + terminatingSignal, error: nil)
    }
}
