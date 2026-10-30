#if !os(WASI) // Files shared between processes; the browser has none.
import DripCore
import Foundation
import Testing

/// The queue's files, on a real directory, with processes the test starts and stops.
final class QueueDirectoryTests {
    private let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("drip-queue-\(UUID().uuidString)")
    /// The processes that run, by pid, and when each started.
    private var running: [Int32: UInt64] = [:]

    deinit { try? FileManager.default.removeItem(atPath: root) }

    private var queue: QueueDirectory {
        let running = running
        return QueueDirectory(
            path: root,
            isAlive: { running[$0.pid] == $0.start },
            processStart: { running[$0] })
    }

    /// Starts a process and queues its card, `stamp` nanoseconds since 1970.
    @discardableResult
    private func run(_ pid: Int32, started: UInt64 = 1, stamp: UInt64, cards: [String] = ["card"]) -> String {
        running[pid] = started
        return queue.enqueue(pid: pid, cards: cards.map { Card(preset: .info, title: $0) }, stamp: stamp)
    }

    /// Queue order is the order drips were run in, not the order of their pids.
    @Test func dripsAreServedInTheOrderTheyWereRun() {
        run(300, stamp: 1)
        run(200, stamp: 2)
        run(100, stamp: 3)
        #expect(queue.isFirst(300))
        #expect(!queue.isFirst(200))
        #expect(!queue.isFirst(100))
        queue.leave(300)
        #expect(queue.isFirst(200))
        #expect(!queue.isFirst(100))
        queue.leave(200)
        #expect(queue.isFirst(100))
    }

    /// A drip killed before it could leave must not hold up every drip behind it.
    @Test func aDeadDripAtTheHeadIsClearedWithItsClaims() throws {
        let dead = run(100, stamp: 1)
        run(200, stamp: 2)
        queue.claim("#0", in: dead)
        running[100] = nil
        #expect(queue.isFirst(200))
        #expect(queue.tickets().map(\.pid) == [200])
        let files = try FileManager.default.contentsOfDirectory(atPath: root).filter { !$0.hasPrefix(".") }
        #expect(files.count == 1, "the dead drip's claim file stays behind: \(files)")
    }

    /// A drip that died in the middle of the queue is skipped once the ones ahead of it are gone.
    @Test func aDeadDripBetweenLiveOnesDoesNotBlockTheOneBehindIt() {
        run(100, stamp: 1)
        run(200, stamp: 2)
        run(300, stamp: 3)
        running[200] = nil
        queue.leave(100)
        #expect(queue.isFirst(300))
    }

    /// A new drip given a dead drip's pid must queue behind the drips ahead of it, not take over
    /// the dead one's place at the head.
    @Test func aPidReusedAfterADripDiedDoesNotAdoptItsTicket() {
        run(100, started: 1, stamp: 1)
        run(200, stamp: 2)
        // The first drip is killed; the system hands its pid to a drip that starts later.
        running[100] = 2
        #expect(queue.ticket(of: 100) == nil)
        #expect(!queue.isFirst(100), "shows ahead of the live drip 200")
        queue.enqueue(pid: 100, cards: [Card(preset: .info, title: "new")], stamp: 3)
        #expect(queue.tickets().map(\.pid) == [200, 100])
        #expect(!queue.isFirst(100))
        queue.leave(200)
        #expect(queue.isFirst(100))
    }

    /// A stack that took over some of a ticket's cards leaves the rest to the drip that queued it.
    @Test func aTicketIsFullyAdoptedOnlyOnceEveryCardIsClaimed() throws {
        let name = run(100, stamp: 1, cards: ["a", "b"])
        queue.claim(CardAdoption.claimKey(index: 0), in: name)
        var ticket = try #require(queue.load().first)
        #expect(ticket.claimed == ["#0"])
        #expect(!ticket.isFullyAdopted)
        queue.claim(CardAdoption.claimKey(index: 1), in: name)
        ticket = try #require(queue.load().first)
        #expect(ticket.claimed == ["#0", "#1"])
        #expect(ticket.isFullyAdopted)
    }

    /// A drip that crashed while writing leaves a hidden temporary file, which is no ticket and
    /// must neither queue nor break the drips reading the directory.
    @Test func aTemporaryFileLeftByACrashIsNoTicket() throws {
        run(100, stamp: 1)
        let leftover = QueueTicket.name(stamp: 0, pid: 999, start: 1)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(root)/.\(leftover).999.tmp", contents: Data("{".utf8))
        running[999] = 1
        #expect(queue.tickets().map(\.pid) == [100])
        #expect(queue.isFirst(100))
        #expect(queue.load().map(\.pid) == [100])
    }

    /// A ticket whose file is empty or garbled still holds its place, without cards.
    @Test func aTicketWithUnreadableContentsStillHoldsItsPlace() throws {
        let name = run(100, stamp: 1)
        run(200, stamp: 2)
        FileManager.default.createFile(atPath: "\(root)/\(name)", contents: Data("not json".utf8))
        #expect(queue.load().map(\.pid) == [100, 200])
        #expect(queue.load().first?.cards.isEmpty == true)
        #expect(!queue.isFirst(200))
    }

    /// A background drip a stack is handed on to takes its parent's place, ahead of drips queued later.
    @Test func aHandedOnDripQueuesRightAfterItsParent() {
        let parent = run(100, stamp: 5)
        run(300, stamp: 6)
        running[200] = 1
        queue.enqueue(pid: 200, cards: [], after: parent)
        #expect(queue.tickets().map(\.pid) == [100, 200, 300])
        #expect(queue.ticket(of: 200) != nil)
    }
}
#endif
