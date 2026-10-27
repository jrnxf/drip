#if !os(WASI) // Spawns processes, which WebAssembly cannot.
import DripCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The commands drip asks about terminal panes: what they print, and a deadline that holds.
struct TimedCommandTests {
    /// What `run` returned, and how long it took.
    func timed(_ arguments: [String], timeout: Double, grace: Double = TimedCommand.grace)
        -> (result: Result<String, TimedCommand.Failure>, seconds: Double)
    {
        let started = Date()
        let result = TimedCommand.run(arguments, timeout: timeout, grace: grace)
        return (result, Date().timeIntervalSince(started))
    }

    /// A temporary file's path, for a command to leave a pid in.
    func scratch() -> String {
        NSTemporaryDirectory() + "drip-timed-\(UUID().uuidString)"
    }

    /// The pid `path` holds, once a command wrote it.
    func pid(at path: String) -> pid_t? {
        (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Whether the process `pid` is gone, within `seconds`: on Linux, dead is enough, as in a container
    /// whose first process never reaps the orphans it inherits.
    func ends(_ pid: pid_t, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            #if os(Linux)
            let stat = (try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8)) ?? ""
            if stat.split(separator: ")").last?.trimmingCharacters(in: .whitespaces).hasPrefix("Z") == true { return true }
            #endif
            usleep(20000)
        }
        return false
    }

    @Test func aCommandThatAnswersInTimeSaysWhatItPrinted() {
        #expect(TimedCommand.run(["printf", "%s\\n", "one", "two"], timeout: 5) == .success("one\ntwo\n"))
        // `NAME=value` first sets the program's environment, as for herdr's socket.
        #expect(TimedCommand.run(["DRIP_TIMED=yes", "sh", "-c", "echo $DRIP_TIMED"], timeout: 5) == .success("yes\n"))
        // Nothing to read on stdin.
        #expect(TimedCommand.run(["cat"], timeout: 5) == .success(""))
    }

    @Test func aCommandThatFailsSaysHowAndWhatItWroteToStderr() {
        #expect(TimedCommand.run(["sh", "-c", "echo out; echo nope >&2; exit 3"], timeout: 5)
            == .failure(TimedCommand.Failure(stderr: "nope\n", reason: "exit status 3")))
        #expect(TimedCommand.run(["sh", "-c", "kill -TERM $$"], timeout: 5)
            == .failure(TimedCommand.Failure(stderr: "", reason: "killed by signal \(SIGTERM)")))
        guard case let .failure(missing) = TimedCommand.run(["drip-no-such-program"], timeout: 5) else {
            Issue.record("a missing program answered")
            return
        }
        #expect(missing.reason == "exit status 127")
        #expect(missing.stderr.contains("drip-no-such-program"))
    }

    @Test func muchOnStderrNeverHoldsTheAnswerUp() {
        // More than a pipe holds, on both, before the command ends.
        let (result, seconds) = timed(["sh", "-c", "i=0; while [ $i -lt 20000 ]; do echo 'a line of stderr, and more'; echo out; i=$((i+1)); done >&2; echo done"], timeout: 20)
        #expect(result == .success("done\n"))
        #expect(seconds < 20)
        guard case let .failure(failure) = TimedCommand.run(["sh", "-c", "head -c 300000 /dev/zero | tr '\\0' x >&2; exit 1"], timeout: 20) else {
            Issue.record("a failing command answered")
            return
        }
        #expect(failure.stderr.count == 300_000)
        #expect(failure.reason == "exit status 1")
    }

    @Test func aCommandThatIgnoresSIGTERMIsKilled() {
        let path = scratch()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // The shell and its sleep both ignore SIGTERM.
        let (result, seconds) = timed(["sh", "-c", "trap '' TERM; echo $$ > '\(path)'; sleep 30"], timeout: 0.5)
        #expect(result == .failure(TimedCommand.Failure(stderr: "", reason: "no answer within 0.5s")))
        #expect(seconds < 0.5 + TimedCommand.grace + 1)
        #expect(pid(at: path).map { ends($0, within: 5) } == true)
    }

    @Test func aProcessLeftBehindHoldingTheOutputEndsToo() {
        let path = scratch()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // The shell answers and exits at once, but the sleep it started keeps its stdout open.
        let (result, seconds) = timed(["sh", "-c", "sleep 30 & echo $! > '\(path)'; echo answer"], timeout: 0.5)
        #expect(result == .failure(TimedCommand.Failure(stderr: "", reason: "no answer within 0.5s")))
        #expect(seconds < 0.5 + TimedCommand.grace + 1)
        #expect(pid(at: path).map { ends($0, within: 5) } == true)
    }

    @Test func aProcessThatLeftTheGroupHoldingTheOutputHoldsNothingUp() {
        let path = scratch()
        defer {
            if let left = pid(at: path) { kill(left, SIGKILL) }
            try? FileManager.default.removeItem(atPath: path)
        }
        // Out of the command's process group, so no signal of drip's reaches it, and it keeps stdout
        // and stderr open for 30 seconds.
        let (result, seconds) = timed(["sh", "-c", "perl -e 'setpgrp(0, 0); print STDERR \"$$\\n\"; sleep 30' 2> '\(path)' & sleep 0.2; echo answer"], timeout: 0.5)
        #expect(result == .failure(TimedCommand.Failure(stderr: "", reason: "no answer within 0.5s")))
        #expect(seconds < 0.5 + TimedCommand.grace + 1)
    }

    @Test func anExitZeroAfterTheDeadlineIsNoAnswer() {
        // SIGTERM ends the shell with status 0 after the deadline.
        let (late, seconds) = timed(["sh", "-c", "trap 'exit 0' TERM; echo early; sleep 30 & wait"], timeout: 0.5)
        #expect(late == .failure(TimedCommand.Failure(stderr: "", reason: "no answer within 0.5s")))
        #expect(seconds < 0.5 + TimedCommand.grace + 1)
        // It exits 0 by itself during the grace, and that is no answer either; drip takes no longer
        // than it does.
        let (ignored, waited) = timed(["sh", "-c", "trap '' TERM; sleep 1; echo late"], timeout: 0.5, grace: 10)
        #expect(ignored == .failure(TimedCommand.Failure(stderr: "", reason: "no answer within 0.5s")))
        #expect(waited > 0.9 && waited < 5)
    }
}
#endif
