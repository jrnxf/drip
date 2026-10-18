import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where blip keeps what it remembers between runs: the card history and the cards held while the
/// screen is locked.
public enum StateDirectory {
    /// `$XDG_STATE_HOME/blip`, falling back to `~/.local/state/blip`.
    public static func path(environment: [String: String]) -> String {
        let base: String
        if let xdg = environment["XDG_STATE_HOME"], xdg.hasPrefix("/") {
            base = xdg
        } else {
            let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            base = ((home as NSString).appendingPathComponent(".local") as NSString).appendingPathComponent("state")
        }
        return (base as NSString).appendingPathComponent("blip")
    }
}

/// A problem reading or writing blip's state files.
public struct StateError: Error, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// One card in the history.
public struct HistoryEntry: Equatable, Sendable, Codable {
    /// When the card came up.
    public var time: Date
    /// True when the screen was locked as the card came up, so it was held until the unlock.
    public var missed: Bool
    public var card: Card

    public init(time: Date, missed: Bool, card: Card) {
        self.time = time
        self.missed = missed
        self.card = card
    }
}

/// Every card blip showed or held, newest last, as one JSON object per line. The oldest entries go
/// once there are more than `limit`.
public struct CardHistory {
    /// The most entries kept.
    public static let limit = 1000

    public var path: String
    public var limit: Int

    public init(path: String, limit: Int = CardHistory.limit) {
        self.path = path
        self.limit = limit
    }

    /// `history.jsonl` in the state directory.
    public init(environment: [String: String]) {
        self.init(path: (StateDirectory.path(environment: environment) as NSString).appendingPathComponent("history.jsonl"))
    }

    /// Adds the cards, dropping the oldest entries beyond `limit`. Safe to call from many blips at once.
    public func record(_ cards: [Card], missed: Bool, at time: Date = Date()) throws {
        guard !cards.isEmpty else { return }
        let added = try cards.map { try HistoryListing.json(HistoryEntry(time: time, missed: missed, card: $0)) }
        try StateFiles.locked(path) {
            let lines = StateFiles.lines(atPath: path) + added
            try StateFiles.write(lines.suffix(limit).map { $0 + "\n" }.joined(), toPath: path)
        }
    }

    /// Every entry, oldest first. Lines that cannot be read are skipped.
    public func entries() -> [HistoryEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return StateFiles.lines(atPath: path).compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
    }
}

/// What `blip history` prints and replays.
public enum HistoryListing {
    /// The entries, only the missed ones when `missed`, oldest first.
    public static func select(_ entries: [HistoryEntry], missed: Bool) -> [HistoryEntry] {
        entries.filter { !missed || $0.missed }
    }

    /// `2026-10-18 14:02  fail  deploy failed - api 1.4.2  (missed)`, in local time.
    public static func line(_ entry: HistoryEntry, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var line = "\(formatter.string(from: entry.time))  \(entry.card.kind)  \(entry.card.title)"
        if let detail = entry.card.detail { line += " - \(detail)" }
        if entry.missed { line += "  (missed)" }
        return line
    }

    /// The entry as one line of JSON, as it is stored.
    public static func json(_ entry: HistoryEntry) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(entry), as: UTF8.self)
    }

    /// The card to show again. A question's button goes, since nothing waits for its answer now; a
    /// button that opens something stays.
    public static func replay(_ entry: HistoryEntry) -> Card {
        var card = entry.card
        if card.action?.open == nil { card.action = nil }
        return card
    }
}

/// Cards that came up while the screen was locked, kept until it unlocks.
///
/// Every background blip that finds the screen locked at its turn adds its cards here and exits.
/// The first of them becomes the holder: it waits for the unlock, then takes every held card and
/// shows them. When a holder dies before the unlock, the next blip takes over its cards.
public struct HeldCards {
    /// What a blip does with its cards.
    public enum Admission: Equatable {
        /// The screen is unlocked: show these cards, left behind by a holder that died, then the
        /// blip's own.
        case show(held: [Card])
        /// The cards are held, and a live holder shows them on the unlock.
        case held
        /// The cards are held, and this blip is now the holder: wait for the unlock, then `release`.
        case holding
    }

    public var directory: String
    /// When a process started, or nil when no process has the id; replaceable so tests can stand
    /// in for other blips. A holder is alive while its id still names the process that started
    /// then, so an id reused after a logout or restart is not mistaken for it.
    public var processStart: (Int32) -> UInt64?

    public init(directory: String, processStart: @escaping (Int32) -> UInt64? = HeldCards.processStartTime) {
        self.directory = directory
        self.processStart = processStart
    }

    /// Held cards in the state directory.
    public init(environment: [String: String]) {
        self.init(directory: StateDirectory.path(environment: environment))
    }

    private var cardsPath: String { (directory as NSString).appendingPathComponent("held.jsonl") }
    private var holderPath: String { (directory as NSString).appendingPathComponent("held.pid") }

    /// Decides what the blip with process id `pid` does with `cards`, given whether the screen is locked.
    public func admit(_ cards: [Card], locked: Bool, pid: Int32) throws -> Admission {
        try StateFiles.locked(cardsPath) {
            let holder = (StateFiles.lines(atPath: holderPath).first ?? "").split(separator: " ")
            let holderIsAlive: Bool
            if holder.count == 2, let holderPID = Int32(holder[0]), let start = UInt64(holder[1]) {
                holderIsAlive = processStart(holderPID) == start
            } else {
                holderIsAlive = false
            }
            guard locked else {
                return .show(held: holderIsAlive ? [] : try takeAll())
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let added = try cards.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            try StateFiles.write(
                (StateFiles.lines(atPath: cardsPath) + added).map { $0 + "\n" }.joined(), toPath: cardsPath)
            if holderIsAlive { return .held }
            try StateFiles.write("\(pid) \(processStart(pid) ?? 0)\n", toPath: holderPath)
            return .holding
        }
    }

    /// Takes every held card, oldest first, and gives up being the holder.
    public func release() throws -> [Card] {
        try StateFiles.locked(cardsPath) { try takeAll() }
    }

    /// Takes every held card and clears the holder. Call with the lock held.
    private func takeAll() throws -> [Card] {
        let decoder = JSONDecoder()
        let cards = StateFiles.lines(atPath: cardsPath).compactMap { try? decoder.decode(Card.self, from: Data($0.utf8)) }
        for path in [cardsPath, holderPath] where unlink(path) != 0 && errno != ENOENT {
            throw StateError("cannot remove \(path): \(String(cString: strerror(errno)))")
        }
        return cards
    }

    /// When the process with the id started, in microseconds since 1970 on macOS and in clock
    /// ticks since boot elsewhere; nil when no process has the id.
    public static func processStartTime(_ pid: Int32) -> UInt64? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
        #else
        // Field 22 of /proc/<pid>/stat, counting the fields after the command name, which can hold spaces.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let end = stat.lastIndex(of: ")")
        else { return nil }
        let fields = stat[stat.index(after: end)...].split(separator: " ")
        return fields.count > 19 ? UInt64(fields[19]) : nil
        #endif
    }
}

/// What the screen shows of the cards held while it was locked: up to two as they are, and three or
/// more as one card that sums them up, so the unlock is not a long line of cards.
public enum MissedSummary {
    /// The fewest held cards that are summed up into one.
    public static let threshold = 3

    public static func cards(for held: [Card]) -> [Card] {
        guard held.count >= threshold, var card = mostSevere(held) else { return held }
        card.title = "\(held.count) cards while you were away"
        // Newest first: what happened last is likely what matters now.
        card.detail = CardText.line(held.reversed().map(\.title).joined(separator: " · "), limit: Defaults.detailLimit)
        card.seconds = held.map(\.seconds).max() ?? card.seconds
        card.action = nil
        card.id = nil
        card.activate = Set(held.map(\.activate)).count == 1 ? held[0].activate : nil
        return [card]
    }

    /// The newest fail card, else the newest warn card, else the newest card: the summary takes its
    /// look and sound, so a failure among the held cards still reads as one.
    private static func mostSevere(_ cards: [Card]) -> Card? {
        for kind in [Preset.fail.name, Preset.warn.name] {
            if let card = cards.last(where: { $0.kind == kind }) { return card }
        }
        return cards.last
    }
}

/// Small, private, crash-safe state files shared by every blip of this user.
enum StateFiles {
    /// Runs `body` holding an exclusive lock on `<path>.lock`, creating the directory as needed.
    static func locked<Value>(_ path: String, _ body: () throws -> Value) throws -> Value {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw StateError("cannot create \(directory): \(error.localizedDescription)")
        }
        let lockPath = path + ".lock"
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StateError("cannot open \(lockPath): \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw StateError("cannot lock \(lockPath): \(String(cString: strerror(errno)))") }
        }
        return try body()
    }

    /// The file's non-empty lines; none when it is missing.
    static func lines(atPath path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Replaces the file in one step, readable only by this user, so a crash never leaves half of it.
    static func write(_ text: String, toPath path: String) throws {
        let temporary = path + ".tmp"
        guard FileManager.default.createFile(
            atPath: temporary, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        else { throw StateError("cannot write \(temporary)") }
        guard rename(temporary, path) == 0 else {
            throw StateError("cannot replace \(path): \(String(cString: strerror(errno)))")
        }
    }
}
