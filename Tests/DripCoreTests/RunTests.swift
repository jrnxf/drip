#if !os(WASI) // Spawns processes, which WebAssembly cannot.
import DripCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// One at a time: a test changes how this process handles SIGINT.
@Suite(.serialized) struct RunTests {
    @Test func duration() {
        #expect(RunSummary.duration(seconds: 0) == "0.0s")
        #expect(RunSummary.duration(seconds: 3.14) == "3.1s")
        #expect(RunSummary.duration(seconds: 9.99) == "9.9s")
        #expect(RunSummary.duration(seconds: 10) == "10s")
        #expect(RunSummary.duration(seconds: 42.7) == "42s")
        #expect(RunSummary.duration(seconds: 60) == "1m 0s")
        #expect(RunSummary.duration(seconds: 192.4) == "3m 12s")
        #expect(RunSummary.duration(seconds: 3840) == "1h 4m 0s")
    }

    @Test func title() {
        #expect(RunSummary.title(command: ["make", "test"], status: 0) == "make test finished")
        #expect(RunSummary.title(command: ["false"], status: 1) == "false failed (exit 1)")
        #expect(RunSummary.title(command: ["sh", "-c", "a\nb"], status: 130) == "sh -c a b failed (exit 130)")
    }

    @Test func longCommandKeepsTheOutcome() {
        let command = ["./deploy.sh"] + Array(repeating: "--verbose", count: 30)
        let failed = RunSummary.title(command: command, status: 1)
        #expect(failed.count == 80)
        #expect(failed.hasSuffix("… failed (exit 1)"), "\(failed)")
        let finished = RunSummary.title(command: command, status: 0)
        #expect(finished.count == 80)
        #expect(finished.hasSuffix("… finished"), "\(finished)")
    }

    @Test func runnerReportsExitCodes() {
        #expect(CommandRunner.run(["true"]).status == 0)
        #expect(CommandRunner.run(["false"]).status == 1)
        #expect(CommandRunner.run(["sh", "-c", "exit 7"]).status == 7)
        #expect(CommandRunner.run(["true"]).error == nil)
    }

    @Test func runnerReportsSignals() {
        #expect(CommandRunner.run(["sh", "-c", "kill -TERM $$"]).status == 128 + SIGTERM)
        // The command gets the default SIGINT handler back even though drip ignores it.
        #expect(CommandRunner.run(["sh", "-c", "kill -INT $$"]).status == 128 + SIGINT)
        #expect(CommandRunner.run(["sh", "-c", "kill -INT $$"]).signal == SIGINT)
        #expect(CommandRunner.run(["sh", "-c", "exit 130"]).signal == nil)
    }

    @Test func runnerKeepsSignalsIgnoredThatWereIgnored() {
        // As for `drip run -- job &` in a script: the shell started drip with SIGINT ignored.
        let previous = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, previous) }
        let outcome = CommandRunner.run(["sh", "-c", "kill -INT $$; exit 7"])
        #expect(outcome.status == 7)
        // With nothing to end it, drip carries on.
        CommandRunner.endLikeTheCommand(CommandRunner.Outcome(status: 130, signal: SIGINT))
    }

    @Test func runnerReportsAMissingCommand() {
        let outcome = CommandRunner.run(["drip-test-no-such-command"])
        #expect(outcome.status == 127)
        #expect(outcome.error == "drip-test-no-such-command: command not found")
    }

    @Test func runnerPassesTheEnvironment() throws {
        // Checks a variable the test process already has: tests run in parallel, so setting one would race.
        let path = try #require(ProcessInfo.processInfo.environment["PATH"])
        #expect(CommandRunner.run(["sh", "-c", "test \"$PATH\" = \"$1\"", "sh", path]).status == 0)
    }

    @Test func runnerPassesArgumentsVerbatim() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drip-run-\(getpid())")
        defer { try? FileManager.default.removeItem(at: file) }
        let outcome = CommandRunner.run(["sh", "-c", "printf '%s|' \"$@\" > \"$0\"", file.path, "a b", "--x", "'q'"])
        #expect(outcome.status == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "a b|--x|'q'|")
    }
}

struct StandardInputTests {
    @Test func readsUntilEndOfFile() {
        #expect(read("hello\nworld\n", limit: 1024) == "hello\nworld\n")
    }

    @Test func noDataIsNil() {
        #expect(read("", limit: 1024) == nil)
    }

    @Test func stopsAtTheLimit() {
        #expect(read(String(repeating: "a", count: 100), limit: 10) == String(repeating: "a", count: 10))
        #expect(StandardInput.limit == 64 * 1024)
    }

    @Test func dropsASequenceCutAtTheLimit() {
        #expect(read("aé", limit: 2) == "a")
    }

    @Test func readsPastTheLimitToTheEnd() throws {
        // A writer with more than the limit to say, as in `./backup.sh | drip ok`: every write gets
        // through, instead of the writer dying of a closed pipe.
        signal(SIGPIPE, SIG_IGN)
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        let chunk = [UInt8](repeating: UInt8(ascii: "a"), count: 50 * 1024)
        let written = Written()
        let input = descriptors[1]
        let writer = Thread {
            for _ in 0..<4 { written.results.append(write(input, chunk, chunk.count)) }
            close(input)
        }
        writer.start()
        // Returns at end of file, which comes only after the writer's last write.
        let text = StandardInput.read(from: descriptors[0], limit: StandardInput.limit)
        close(descriptors[0])
        #expect(text == String(repeating: "a", count: StandardInput.limit))
        #expect(written.results == Array(repeating: chunk.count, count: 4))
    }

    private func read(_ text: String, limit: Int) -> String? {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let bytes = Array(text.utf8)
        if !bytes.isEmpty {
            #expect(write(descriptors[1], bytes, bytes.count) == bytes.count)
        }
        close(descriptors[1])
        defer { close(descriptors[0]) }
        return StandardInput.read(from: descriptors[0], limit: limit)
    }
}

/// What a writer thread's calls returned, read once the thread has closed its end of the pipe.
private final class Written: @unchecked Sendable {
    var results: [Int] = []
}
#endif
