@testable import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import Testing

/// `drip pause`: its durations, what it says, and the end time every drip reads.
final class PauseTests {
    @Test func durationsInMinutesAndHours() {
        #expect(DripPause.duration("30m") == 1800)
        #expect(DripPause.duration("2h") == 7200)
        #expect(DripPause.duration("1h30m") == 5400)
        #expect(DripPause.duration("90m") == 5400)
        #expect(DripPause.duration("2H") == 7200)
        for text in ["", "30", "m", "h30", "30s", "1d", "30m1h", "1h1h", "1.5h", "-30m", "30 m", "0m", "0h0m"] {
            #expect(DripPause.duration(text) == nil, "\(text)")
        }
    }

    @Test func timeLeftRoundsUpToTheMinute() {
        #expect(DripPause.describe(seconds: 3600) == "1h")
        #expect(DripPause.describe(seconds: 3599.5) == "1h")
        #expect(DripPause.describe(seconds: 5400) == "1h 30m")
        #expect(DripPause.describe(seconds: 2700) == "45m")
        #expect(DripPause.describe(seconds: 61) == "2m")
        #expect(DripPause.describe(seconds: 5) == "1m")
        #expect(DripPause.describe(seconds: 0) == "1m")
    }

    @Test func statusSaysWhenThePauseEnds() {
        let utc = TimeZone(secondsFromGMT: 0)!
        // 2026-10-22 14:00 UTC.
        let now = Date(timeIntervalSince1970: 1_792_677_600)
        #expect(DripPause.status(end: now.addingTimeInterval(3600), now: now, timeZone: utc)
            == "drip is paused until 15:00 (1h left)")
        #expect(DripPause.status(end: now.addingTimeInterval(65 * 60), now: now, timeZone: utc)
            == "drip is paused until 15:05 (1h 5m left)")
        #expect(DripPause.status(end: now.addingTimeInterval(11 * 3600), now: now, timeZone: utc)
            == "drip is paused until tomorrow 01:00 (11h left)")
    }

    @Test func theReminderSaysHowLongIsLeft() {
        let now = Date(timeIntervalSince1970: 1_792_677_600)
        #expect(DripPause.reminder(end: now.addingTimeInterval(23 * 60), now: now)
            == "drip is paused, 23m left (drip resume to unpause)")
    }

    #if !os(WASI) // Files the drips share; the browser has none.
    /// Every file one test writes; removed after it.
    private let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("drip-tests-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func thePauseLivesInTheStateDirectory() {
        #expect(DripPause(environment: ["XDG_STATE_HOME": "/s", "HOME": "/h"]).path == "/s/drip/pause")
        #expect(DripPause(environment: ["HOME": "/h"]).path == "/h/.local/state/drip/pause")
    }

    @Test func aPauseHoldsUntilItEnds() throws {
        let pause = DripPause(path: root + "/state/pause")
        let now = Date(timeIntervalSince1970: 1_792_677_600)
        #expect(pause.end(now: now) == nil)
        #expect(!pause.isPaused(now: now))
        try pause.pause(until: now.addingTimeInterval(1800))
        #expect(pause.end(now: now) == now.addingTimeInterval(1800))
        #expect(pause.isPaused(now: now.addingTimeInterval(1799)))
        // It ends on its own.
        #expect(!pause.isPaused(now: now.addingTimeInterval(1800)))
        #expect(pause.end(now: now.addingTimeInterval(3600)) == nil)
    }

    @Test func pausingAgainSetsANewEnd() throws {
        let pause = DripPause(path: root + "/pause")
        let now = Date(timeIntervalSince1970: 1_792_677_600)
        try pause.pause(until: now.addingTimeInterval(7200))
        try pause.pause(until: now.addingTimeInterval(600))
        #expect(pause.end(now: now) == now.addingTimeInterval(600))
        // Another drip, as every drip makes its own, reads the same end.
        #expect(DripPause(path: root + "/pause").end(now: now) == now.addingTimeInterval(600))
    }

    @Test func resumeEndsThePauseAndSaysWhetherThereWasOne() throws {
        let pause = DripPause(path: root + "/pause")
        let now = Date(timeIntervalSince1970: 1_792_677_600)
        #expect(try !pause.resume(now: now))
        try pause.pause(until: now.addingTimeInterval(600))
        #expect(try pause.resume(now: now))
        #expect(!pause.isPaused(now: now))
        #expect(!FileManager.default.fileExists(atPath: pause.path))
        // A pause that already ended is not one.
        try pause.pause(until: now.addingTimeInterval(-1))
        #expect(try !pause.resume(now: now))
    }

    @Test func aFileThatIsNotAnEndTimeIsNoPause() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "soon\n".write(toFile: root + "/pause", atomically: true, encoding: .utf8)
        #expect(DripPause(path: root + "/pause").end() == nil)
    }
    #endif
}
