import BlipCore
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class RunTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(RunSummary.duration(seconds: 0), "0.0s")
        XCTAssertEqual(RunSummary.duration(seconds: 3.14), "3.1s")
        XCTAssertEqual(RunSummary.duration(seconds: 9.99), "9.9s")
        XCTAssertEqual(RunSummary.duration(seconds: 10), "10s")
        XCTAssertEqual(RunSummary.duration(seconds: 42.7), "42s")
        XCTAssertEqual(RunSummary.duration(seconds: 60), "1m 0s")
        XCTAssertEqual(RunSummary.duration(seconds: 192.4), "3m 12s")
        XCTAssertEqual(RunSummary.duration(seconds: 3840), "1h 4m 0s")
    }

    func testTitle() {
        XCTAssertEqual(RunSummary.title(command: ["make", "test"], status: 0), "make test finished")
        XCTAssertEqual(RunSummary.title(command: ["false"], status: 1), "false failed (exit 1)")
        XCTAssertEqual(RunSummary.title(command: ["sh", "-c", "a\nb"], status: 130), "sh -c a b failed (exit 130)")
    }

    func testLongCommandKeepsTheOutcome() {
        let command = ["./deploy.sh"] + Array(repeating: "--verbose", count: 30)
        let failed = RunSummary.title(command: command, status: 1)
        XCTAssertEqual(failed.count, 80)
        XCTAssertTrue(failed.hasSuffix("… failed (exit 1)"), failed)
        let finished = RunSummary.title(command: command, status: 0)
        XCTAssertEqual(finished.count, 80)
        XCTAssertTrue(finished.hasSuffix("… finished"), finished)
    }

    func testRunnerReportsExitCodes() {
        XCTAssertEqual(CommandRunner.run(["true"]).status, 0)
        XCTAssertEqual(CommandRunner.run(["false"]).status, 1)
        XCTAssertEqual(CommandRunner.run(["sh", "-c", "exit 7"]).status, 7)
        XCTAssertNil(CommandRunner.run(["true"]).error)
    }

    func testRunnerReportsSignals() {
        XCTAssertEqual(CommandRunner.run(["sh", "-c", "kill -TERM $$"]).status, 128 + SIGTERM)
        // The command gets the default SIGINT handler back even though blip ignores it.
        XCTAssertEqual(CommandRunner.run(["sh", "-c", "kill -INT $$"]).status, 128 + SIGINT)
    }

    func testRunnerReportsAMissingCommand() {
        let outcome = CommandRunner.run(["blip-test-no-such-command"])
        XCTAssertEqual(outcome.status, 127)
        XCTAssertEqual(outcome.error, "blip-test-no-such-command: command not found")
    }

    func testRunnerPassesArgumentsVerbatim() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blip-run-\(getpid())")
        defer { try? FileManager.default.removeItem(at: file) }
        let outcome = CommandRunner.run(["sh", "-c", "printf '%s|' \"$@\" > \"$0\"", file.path, "a b", "--x", "'q'"])
        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "a b|--x|'q'|")
    }
}

final class StandardInputTests: XCTestCase {
    func testReadsUntilEndOfFile() {
        XCTAssertEqual(read("hello\nworld\n", limit: 1024), "hello\nworld\n")
    }

    func testNoDataIsNil() {
        XCTAssertNil(read("", limit: 1024))
    }

    func testStopsAtTheLimit() {
        XCTAssertEqual(read(String(repeating: "a", count: 100), limit: 10), String(repeating: "a", count: 10))
        XCTAssertEqual(StandardInput.limit, 64 * 1024)
    }

    func testDropsASequenceCutAtTheLimit() {
        XCTAssertEqual(read("aé", limit: 2), "a")
    }

    private func read(_ text: String, limit: Int) -> String? {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        let bytes = Array(text.utf8)
        if !bytes.isEmpty {
            XCTAssertEqual(write(descriptors[1], bytes, bytes.count), bytes.count)
        }
        close(descriptors[1])
        defer { close(descriptors[0]) }
        return StandardInput.read(from: descriptors[0], limit: limit)
    }
}
