import DripCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The card history, the cards held while the screen is locked, and the summary shown on unlock.
final class HistoryTests {
    /// Every file one test writes; removed after it.
    private let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("drip-tests-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func stateDirectoryFollowsXDG() {
        #expect(StateDirectory.path(environment: ["XDG_STATE_HOME": "/s", "HOME": "/h"]) == "/s/drip")
        #expect(StateDirectory.path(environment: ["HOME": "/h"]) == "/h/.local/state/drip")
        // A relative XDG_STATE_HOME is ignored, as the spec says.
        #expect(StateDirectory.path(environment: ["XDG_STATE_HOME": "state", "HOME": "/h"]) == "/h/.local/state/drip")
        #expect(CardHistory(environment: ["HOME": "/h"]).path == "/h/.local/state/drip/history.jsonl")
    }

    @Test func recordsAndReadsBackOldestFirst() throws {
        let history = CardHistory(path: try scratch().appending("/state/history.jsonl"))
        #expect(history.entries().isEmpty)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        try history.record([card("one"), card("two", kind: "fail")], missed: false, at: time)
        try history.record([card("three")], missed: true, at: time.addingTimeInterval(60))
        let entries = history.entries()
        #expect(entries.map(\.card.title) == ["one", "two", "three"])
        #expect(entries.map(\.missed) == [false, false, true])
        #expect(entries[0].time == time)
        #expect(entries[1].card == card("two", kind: "fail"))
    }

    @Test func keepsOnlyTheNewestEntries() throws {
        let history = CardHistory(path: try scratch().appending("/history.jsonl"), limit: 3)
        for index in 1...5 {
            try history.record([card("card \(index)")], missed: false)
        }
        #expect(history.entries().map(\.card.title) == ["card 3", "card 4", "card 5"])
        try history.record([card("a"), card("b"), card("c"), card("d")], missed: true)
        #expect(history.entries().map(\.card.title) == ["b", "c", "d"])
        let lines = try String(contentsOfFile: history.path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
    }

    @Test func theJSONListingIsFlat() throws {
        var deploy = card("deployed", kind: "deploy")
        deploy.detail = "api 1.4.2"
        deploy.color = .rgb(red: 0xA7, green: 0x8B, blue: 0xFA)
        deploy.sound = .file("/tmp/ding.aiff")
        deploy.action = CardAction(label: "View run", open: "https://example.com/run/1")
        deploy.id = "deploy"
        let entry = HistoryEntry(time: Date(timeIntervalSince1970: 1_800_000_000), missed: true, card: deploy)
        #expect(try HistoryListing.publicJSON(entry) == ##"{"card":{"button":"View run","color":"#a78bfa","##
            + ##""detail":"api 1.4.2","icon":"paperplane.fill","id":"deploy","kind":"deploy","motion":"full","##
            + ##""open":"https://example.com/run/1","position":"notch","seconds":4.5,"size":"regular","##
            + ##""sound":"/tmp/ding.aiff","style":"hud","title":"deployed"},"missed":true,"##
            + ##""time":"2027-01-15T08:00:00Z"}"##)
        let quiet = HistoryEntry(time: entry.time, missed: false, card: card("ok", kind: "ok"))
        #expect(try HistoryListing.publicJSON(quiet).contains(#""color":"green""#))
        #expect(try HistoryListing.publicJSON(quiet).contains(#""sound":"Glass""#))
    }

    @Test func keepsTheStartOfVeryLongText() throws {
        let history = CardHistory(path: try scratch().appending("/history.jsonl"))
        var long = card(String(repeating: "t", count: 20_000))
        long.detail = String(repeating: "d", count: 4 * 1024 * 1024)
        try history.record([long], missed: false)
        let kept = try #require(history.entries().first?.card)
        #expect(kept.title.count == CardHistory.textLimit)
        #expect(kept.title.hasSuffix("…"))
        #expect(kept.detail?.count == CardHistory.textLimit)
    }

    @Test func historyIsPrivate() throws {
        let directory = try scratch().appending("/state")
        let history = CardHistory(path: directory + "/history.jsonl")
        try history.record([card("secret")], missed: false)
        let file = try FileManager.default.attributesOfItem(atPath: history.path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: directory)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func skipsLinesItCannotRead() throws {
        let history = CardHistory(path: try scratch().appending("/history.jsonl"))
        try history.record([card("good")], missed: false)
        let handle = try #require(FileHandle(forWritingAtPath: history.path))
        handle.seekToEndOfFile()
        handle.write(Data("not json\n{\"time\":1}\n".utf8))
        try handle.close()
        try history.record([card("after")], missed: false)
        #expect(history.entries().map(\.card.title) == ["good", "after"])
    }

    @Test func concurrentRecordsAreAllKept() throws {
        let history = CardHistory(path: try scratch().appending("/history.jsonl"), limit: 500)
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            try? history.record([card("card \(index)")], missed: false)
        }
        #expect(Set(history.entries().map(\.card.title)) == Set((0..<40).map { "card \($0)" }))
    }

    @Test func listingSelectsEverythingOrTheMissed() {
        let entries = (1...6).map {
            HistoryEntry(time: Date(timeIntervalSince1970: Double($0)), missed: $0 % 2 == 0, card: card("card \($0)"))
        }
        #expect(HistoryListing.select(entries, missed: false) == entries)
        #expect(HistoryListing.select(entries, missed: true).map(\.card.title) == ["card 2", "card 4", "card 6"])
        #expect(HistoryListing.select([], missed: true).isEmpty)
    }

    @Test func listingLines() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let time = Date(timeIntervalSince1970: 1_792_332_120) // 2026-10-18 14:02 UTC
        var deploy = card("deploy failed", kind: "fail")
        deploy.detail = "api 1.4.2"
        #expect(HistoryListing.line(HistoryEntry(time: time, missed: true, card: deploy), timeZone: utc)
            == "2026-10-18 14:02  fail  deploy failed - api 1.4.2  (missed)")
        #expect(HistoryListing.line(HistoryEntry(time: time, missed: false, card: card("built")), timeZone: utc)
            == "2026-10-18 14:02  info  built")
    }

    @Test func jsonIsOneStoredLine() throws {
        let entry = HistoryEntry(time: Date(timeIntervalSince1970: 1_792_332_120), missed: true, card: card("hi"))
        let json = try HistoryListing.json(entry)
        #expect(!json.contains("\n"))
        #expect(json.contains("\"time\":\"2026-10-18T14:02:00Z\""), "\(json)")
        #expect(json.contains("\"missed\":true"), "\(json)")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(HistoryEntry.self, from: Data(json.utf8)) == entry)
    }

    @Test func replayDropsOnlyAQuestionsButton() {
        var question = card("promote?")
        question.action = CardAction(label: "Promote", open: nil)
        #expect(HistoryListing.replay(HistoryEntry(time: Date(), missed: true, card: question)).action == nil)
        var link = card("ci")
        link.action = CardAction(label: "View run", open: "https://example.com")
        #expect(HistoryListing.replay(HistoryEntry(time: Date(), missed: true, card: link)).action == link.action)
    }

    @Test func aReplayAddsNoHistoryEntries() throws {
        let history = CardHistory(path: try scratch().appending("/history.jsonl"))
        try history.record([card("a"), card("b")], missed: true)
        let before = history.entries()
        let replay = BackgroundRequest(cards: before.map(HistoryListing.replay), record: false)
        let received = try BackgroundRequest.decode(replay.encoded())
        try received.locked.record(received.cards, missed: true, in: history)
        try LockedScreen.wait(record: received.record).record(received.cards, missed: false, in: history)
        try LockedScreen.ignore.record(received.cards, missed: false, in: history)
        #expect(history.entries() == before)
        // A card sent as usual is recorded, by either path.
        let sent = try BackgroundRequest.decode(BackgroundRequest(cards: [card("c")]).encoded())
        try sent.locked.record(sent.cards, missed: true, in: history)
        try LockedScreen.wait(record: sent.record).record([card("d")], missed: false, in: history)
        #expect(history.entries().map(\.card.title) == ["a", "b", "c", "d"])
    }

    @Test func aRequestWithoutRecordIsRecorded() throws {
        let request = try BackgroundRequest.decode(Data(#"{"cards":[]}"#.utf8))
        #expect(request.record)
        #expect(request.locked == .pool(record: true))
    }

    // MARK: Holding cards while the screen is locked

    @Test func unlockedCardsShowAtOnce() throws {
        let held = HeldCards(directory: try scratch(), processStart: { _ in 1 })
        #expect(try held.admit([card("a")], locked: false, pid: 100) == .show(held: []))
        #expect(try held.release().isEmpty)
    }

    @Test func theFirstLockedDripHoldsAndTheRestJoinIt() throws {
        let alive: Set<Int32> = [100, 101, 102]
        let held = HeldCards(directory: try scratch(), processStart: { alive.contains($0) ? 1 : nil })
        #expect(try held.admit([card("a")], locked: true, pid: 100) == .holding)
        #expect(try held.admit([card("b")], locked: true, pid: 101) == .held)
        #expect(try held.admit([card("c"), card("d")], locked: true, pid: 102) == .held)
        // A card after the unlock, before the holder has noticed, shows on its own.
        #expect(try held.admit([card("e")], locked: false, pid: 103) == .show(held: []))
        #expect(try held.release().map(\.title) == ["a", "b", "c", "d"])
        // Released: the next lock starts a new hold.
        #expect(try held.release().isEmpty)
        #expect(try held.admit([card("f")], locked: true, pid: 101) == .holding)
    }

    @Test func aDeadHoldersCardsAreTakenOver() throws {
        var alive: Set<Int32> = [100]
        let directory = try scratch()
        let held = HeldCards(directory: directory, processStart: { alive.contains($0) ? 1 : nil })
        #expect(try held.admit([card("a")], locked: true, pid: 100) == .holding)
        alive = [101]
        // Still locked: the next drip becomes the holder and keeps the dead one's cards.
        let next = HeldCards(directory: directory, processStart: { alive.contains($0) ? 1 : nil })
        #expect(try next.admit([card("b")], locked: true, pid: 101) == .holding)
        alive = []
        // Unlocked with no live holder: the next drip shows what was left behind before its own.
        #expect(try next.admit([card("c")], locked: false, pid: 102) == .show(held: [card("a"), card("b")]))
        #expect(try next.release().isEmpty)
    }

    @Test func aHolderIdReusedAfterARestartIsNotTheHolder() throws {
        var starts: [Int32: UInt64] = [100: 1]
        let directory = try scratch()
        let held = HeldCards(directory: directory, processStart: { starts[$0] })
        #expect(try held.admit([card("a")], locked: true, pid: 100) == .holding)
        // After a restart, id 100 is some other process, perhaps one drip cannot signal.
        starts = [100: 2, 101: 3]
        #expect(try held.admit([card("b")], locked: true, pid: 101) == .holding)
        #expect(try held.admit([card("c")], locked: true, pid: 102) == .held)
        starts = [100: 2]
        #expect(try held.admit([card("d")], locked: false, pid: 103) == .show(held: [card("a"), card("b"), card("c")]))
    }

    @Test func aDripGivenADeadHoldersIdTakesOver() throws {
        var starts: [Int32: UInt64] = [100: 1]
        let directory = try scratch()
        let held = HeldCards(directory: directory, processStart: { starts[$0] })
        #expect(try held.admit([card("a")], locked: true, pid: 100) == .holding)
        // The holder died, and a new drip got its id.
        starts = [100: 2, 101: 3]
        #expect(try held.admit([card("b")], locked: true, pid: 100) == .holding)
        #expect(try held.admit([card("c")], locked: true, pid: 101) == .held)
        #expect(try held.release().map(\.title) == ["a", "b", "c"])
    }

    @Test func aHolderFileWithoutAStartTimeHasNoHolder() throws {
        let directory = try scratch()
        try "100\n".write(toFile: directory + "/held.pid", atomically: true, encoding: .utf8)
        let held = HeldCards(directory: directory, processStart: { _ in 1 })
        #expect(try held.admit([card("a")], locked: true, pid: 101) == .holding)
    }

    @Test func realProcessesHaveAStartTime() throws {
        let start = try #require(HeldCards.processStartTime(getpid()))
        #expect(HeldCards.processStartTime(getpid()) == start)
        #expect(HeldCards.processStartTime(Int32.max) == nil)
    }

    // MARK: The summary shown on unlock

    @Test func oneOrTwoHeldCardsShowAsThemselves() {
        #expect(MissedSummary.cards(for: []).isEmpty)
        #expect(MissedSummary.cards(for: [card("a")]) == [card("a")])
        #expect(MissedSummary.cards(for: [card("a"), card("b", kind: "fail")]) == [card("a"), card("b", kind: "fail")])
    }

    @Test func threeOrMoreBecomeOneSummary() throws {
        var link = card("deploy shipped", kind: "ok")
        link.action = CardAction(label: "View", open: "https://example.com")
        link.seconds = 8
        let summary = MissedSummary.cards(for: [card("tests passed", kind: "ok"), link, card("backup done")])
        try #require(summary.count == 1)
        #expect(summary[0].title == "3 cards while you were away")
        #expect(summary[0].detail == "backup done · deploy shipped · tests passed")
        #expect(summary[0].kind == "info")
        #expect(summary[0].seconds == 8)
        #expect(summary[0].action == nil)
    }

    @Test func theSummaryLooksLikeTheWorstCard() throws {
        let cards = [card("a", kind: "warn"), card("b", kind: "fail"), card("c", kind: "ok"), card("d", kind: "fail")]
        let failed = try #require(MissedSummary.cards(for: cards).first)
        #expect(failed.kind == "fail")
        #expect(failed.color == Preset.fail.color)
        #expect(failed.sound == Preset.fail.sound)
        let warned = try #require(MissedSummary.cards(for: [card("a", kind: "warn"), card("b"), card("c", kind: "ok")]).first)
        #expect(warned.kind == "warn")
        let custom = try #require(MissedSummary.cards(for: [card("a", kind: "ok"), card("b"), card("c", kind: "deploy")]).first)
        #expect(custom.kind == "deploy")
    }

    @Test func theSummaryTakesNoCardsIDAndOnlyASharedActivate() throws {
        var cards = [card("a", kind: "fail"), card("b"), card("c")]
        for index in cards.indices {
            cards[index].id = "card-\(index)"
            cards[index].activate = "com.apple.Terminal"
        }
        let shared = try #require(MissedSummary.cards(for: cards).first)
        #expect(shared.id == nil)
        #expect(shared.activate == "com.apple.Terminal")
        cards[0].activate = "com.example.Deploy"
        let mixed = try #require(MissedSummary.cards(for: cards).first)
        #expect(mixed.id == nil)
        #expect(mixed.activate == nil)
    }

    @Test func aLongSummaryKeepsEveryTitle() throws {
        let cards = (1...20).map { card("a fairly long card title number \($0)") }
        let summary = try #require(MissedSummary.cards(for: cards).first)
        #expect(summary.title == "20 cards while you were away")
        let detail = try #require(summary.detail)
        #expect(detail.hasPrefix("a fairly long card title number 20 · "))
        #expect(detail.hasSuffix(" · a fairly long card title number 1"))
    }

    private func card(_ title: String, kind: String = "info") -> Card {
        let preset = Preset.builtIn.first { $0.name == kind } ?? Preset(
            name: kind, icon: .symbol("paperplane.fill"), color: .system(.purple), sound: .named("Submarine"))
        return Card(preset: preset, title: title)
    }

    /// A fresh directory inside this test's root.
    private func scratch() throws -> String {
        let path = (root as NSString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
