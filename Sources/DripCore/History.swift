#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Where drip keeps what it remembers between runs: the card history, the cards held while the
/// screen is locked or drip is paused, and the pause.
public enum StateDirectory {
    /// `$XDG_STATE_HOME/drip`, falling back to `~/.local/state/drip`.
    public static func path(environment: [String: String]) -> String {
        let base: String
        if let xdg = environment["XDG_STATE_HOME"], xdg.hasPrefix("/") {
            base = xdg
        } else {
            let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            base = ((home as NSString).appendingPathComponent(".local") as NSString).appendingPathComponent("state")
        }
        return (base as NSString).appendingPathComponent("drip")
    }
}

/// A problem reading or writing drip's state files.
public struct StateError: Error, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// The lines a card showed on screen, or would have shown to someone at the screen: the title's
/// lines and the detail's, wrapped as the card wraps them, the last of each ending in an ellipsis
/// when the text ran on.
public struct ShownText: Equatable, Sendable, Codable {
    public var title: [String]
    public var detail: [String]

    public init(title: [String], detail: [String] = []) {
        self.title = title
        self.detail = detail
    }

    /// The lines the card would show, estimated from the width of an average character instead of
    /// measured. For cards recorded before the history kept `shown`, and where there is no window
    /// server to measure with, as in a WebAssembly build or over ssh.
    public init(estimating card: Card) {
        let scale = card.size.scale
        // The card's own text column, for a card with its icon and the width of its buttons.
        func buttonWidth(_ label: String) -> Double { (Double(label.count) * 7.5 + 24) * scale }
        let yes = card.action.map { buttonWidth($0.label) }
        let no = card.action?.decline.map(buttonWidth)
        let column = IslandMetrics(
            notchWidth: 0, notchHeight: 0, scale: scale, textWidth: 0, textHeight: 0, hasIcon: card.showsIconAtNotch,
            actionWidth: yes.map { IslandMetrics.buttonsWidth(yes: $0, no: no, scale: scale) } ?? 0,
            declineWidth: no ?? 0
        ).textColumn
        func lines(_ text: String, points: Double, maxLines: Int) -> [String] {
            let size = points * scale
            let cap = max(maxLines, 1) * 400
            let text = text.index(text.startIndex, offsetBy: cap, limitedBy: text.endIndex).map { String(text[..<$0]) } ?? text
            return CardText.wrap(text, width: column, maxLines: maxLines) { string in
                string.reduce(0) { $0 + ($1.unicodeScalars.first.map { $0.value >= 0x2E80 } == true ? 1.0 : 0.56) * size }
            }
        }
        title = lines(card.title, points: 14, maxLines: Defaults.titleLines)
        detail = card.detail.map { lines($0, points: 12, maxLines: Defaults.detailLines) } ?? []
    }
}

/// One card in the history.
public struct HistoryEntry: Equatable, Sendable, Codable {
    /// When the card came up.
    public var time: Date
    /// True when the screen was locked or drip was paused as the card came up, so it was held until
    /// the unlock and the end of the pause.
    public var missed: Bool
    public var card: Card
    /// What the card showed, measured as it was recorded; nil in entries recorded before drip kept it.
    public var shown: ShownText?

    public init(time: Date, missed: Bool, card: Card, shown: ShownText? = nil) {
        self.time = time
        self.missed = missed
        self.card = card
        self.shown = shown
    }

    /// The lines the card showed: the recorded ones, or an estimate from its text.
    public var shownText: ShownText { shown ?? ShownText(estimating: card) }
}

/// Every card drip showed or held, newest last, as one JSON object per line. The oldest entries go
/// once there are more than `limit`.
public struct CardHistory {
    /// The most entries kept.
    public static let limit = 1000
    /// The most characters of a title or a detail an entry keeps. A hook card's detail is the
    /// agent's whole last message, and every card rewrites the file.
    public static let textLimit = 16 * 1024

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

    /// Adds the cards, dropping the oldest entries beyond `limit`. Safe to call from many drips at once.
    ///
    /// - Parameter shown: The lines a card shows, measured with the card's own fonts and width;
    ///   without one, or when it answers nil, the entry keeps none and the listing estimates them.
    public func record(
        _ cards: [Card], missed: Bool, at time: Date = Date(), shown: (Card) -> ShownText? = { _ in nil }
    ) throws {
        guard !cards.isEmpty else { return }
        let added = try cards.map { card in
            var kept = card
            kept.title = CardText.truncate(card.title, limit: Self.textLimit)
            kept.detail = card.detail.map { CardText.truncate($0, limit: Self.textLimit) }
            return try HistoryListing.json(HistoryEntry(time: time, missed: missed, card: kept, shown: shown(card)))
        }
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

/// What `drip history` prints and replays.
public enum HistoryListing {
    /// The entries, only the missed ones when `missed`, oldest first.
    public static func select(_ entries: [HistoryEntry], missed: Bool) -> [HistoryEntry] {
        entries.filter { !missed || $0.missed }
    }

    /// How many cards `drip history` lists without `-n` or `--all`.
    public static let defaultCount = 20
    /// The columns the time takes, and the gap and bar after it.
    static let timeWidth = 9
    /// The least width of the text a rule spans.
    static let ruleMinimum = 40

    /// The newest `count` entries, or all of them when `count` is nil, oldest first.
    public static func newest(_ entries: [HistoryEntry], count: Int?) -> [HistoryEntry] {
        count.map { Array(entries.suffix($0)) } ?? entries
    }

    /// `2m ago`, `3h ago`, `1d ago`: how long before `now` the card came up.
    public static func relativeTime(_ time: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(time))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        if seconds < 365 * 86_400 { return "\(seconds / 86_400)d ago" }
        return "\(seconds / (365 * 86_400))y ago"
    }

    /// What `drip history` prints: the entries newest first, each as its time, a bar in the color
    /// of its kind on every line, its title and the detail lines it showed, with a rule between
    /// cards. `color` adds the escapes; without it the layout is the same in plain text.
    public static func render(_ entries: [HistoryEntry], now: Date = Date(), color: Bool) -> String {
        func style(_ text: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
        let shown = entries.map(\.shownText)
        // The rule spans the time column, the bar and the widest line shown.
        let widest = shown.flatMap { $0.title + $0.detail }.map(\.count).max() ?? 0
        let rule = style(String(repeating: "─", count: timeWidth + 2 + max(widest, ruleMinimum)), "2")
        let blank = String(repeating: " ", count: timeWidth)
        let cards = zip(entries, shown).reversed().map { entry, shown -> String in
            let bar = style("┃", barColor(entry.card.kind))
            let time = relativeTime(entry.time, now: now)
            let first = style(time, "2") + String(repeating: " ", count: max(timeWidth - time.count, 1))
            var lines: [String] = []
            for (index, text) in (shown.title.isEmpty ? [entry.card.title] : shown.title).enumerated() {
                lines.append((index == 0 ? first : blank) + " " + bar + " " + style(text, "1"))
            }
            if entry.missed { lines[lines.count - 1] += "  " + style("missed", "33") }
            for text in shown.detail { lines.append(blank + " " + bar + " " + text) }
            return lines.joined(separator: "\n")
        }
        return cards.joined(separator: "\n" + rule + "\n")
    }

    /// The bar's color: green for ok, yellow for warn, red for fail, blue for info; none for a kind
    /// of the user's own.
    private static func barColor(_ kind: String) -> String {
        switch kind {
        case Preset.ok.name: return "32"
        case Preset.warn.name: return "33"
        case Preset.fail.name: return "31"
        case Preset.info.name: return "34"
        default: return "39"
        }
    }

    /// The entry as one line of JSON, as it is stored.
    public static func json(_ entry: HistoryEntry) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(entry), as: UTF8.self)
    }

    /// What `drip history --json` prints for an entry: one flat object, each card setting written
    /// the way its flag takes it, so scripts can read it. The history file's own encoding is drip's.
    public static func publicJSON(_ entry: HistoryEntry) throws -> String {
        let card = entry.card
        let shown = PublicEntry(
            time: entry.time, missed: entry.missed,
            card: PublicCard(
                kind: card.kind, title: card.title, detail: card.detail, icon: card.icon.argument,
                color: card.color.argument, sound: card.sound.argument, seconds: card.seconds,
                size: card.size.rawValue, motion: card.motion.rawValue, button: card.action?.label, no: card.action?.decline,
                open: card.action?.open, id: card.id, activate: card.activate))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(shown), as: UTF8.self)
    }

    private struct PublicEntry: Encodable {
        var time: Date
        var missed: Bool
        var card: PublicCard
    }

    private struct PublicCard: Encodable {
        var kind: String
        var title: String
        var detail: String?
        var icon: String
        var color: String
        var sound: String
        var seconds: Double
        var size: String
        var motion: String
        var button: String?
        /// A question's no button, as `--no` takes it.
        var no: String?
        var open: String?
        var id: String?
        var activate: String?
    }

    /// The card to show again. A question's button goes, since nothing waits for its answer now; a
    /// button that opens something stays.
    public static func replay(_ entry: HistoryEntry) -> Card {
        var card = entry.card
        if card.action?.open == nil { card.action = nil }
        return card
    }
}

/// Cards that came up while the screen was locked or drip was paused, kept until it unlocks and the
/// pause ends.
///
/// Every background drip that finds the screen locked at its turn adds its cards here and exits.
/// The first of them becomes the holder: it waits for the unlock, then takes every held card and
/// shows them. When a holder dies before the unlock, the next drip takes over its cards.
public struct HeldCards {
    /// What a drip does with its cards.
    public enum Admission: Equatable {
        /// The screen is unlocked: show these cards, left behind by a holder that died, then the
        /// drip's own.
        case show(held: [Card])
        /// The cards are held, and a live holder shows them on the unlock.
        case held
        /// The cards are held, and this drip is now the holder: wait for the unlock, then `release`.
        case holding
    }

    public var directory: String
    /// When a process started, or nil when no process has the id; replaceable so tests can stand
    /// in for other drips. A holder is alive while its id still names the process that started
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

    /// Decides what the drip with process id `pid` does with `cards`, given whether the screen is locked.
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
        card.detail = CardText.line(held.reversed().map(\.title).joined(separator: " · "))
        card.seconds = held.map(\.seconds).max() ?? card.seconds
        // A summary counts down: what it sums up is already in the past.
        card.waitLimit = nil
        card.action = nil
        card.id = nil
        card.activate = Set(held.map(\.activate)).count == 1 ? held[0].activate : nil
        return [card]
    }

    /// The newest fail card, else the newest card that stays, else the newest warn card, else the
    /// newest card: the summary takes its look and sound, so a failure among the held cards still
    /// reads as one, and something waiting on you next.
    private static func mostSevere(_ cards: [Card]) -> Card? {
        cards.last { $0.kind == Preset.fail.name } ?? cards.last(where: \.waits)
            ?? cards.last { $0.kind == Preset.warn.name } ?? cards.last
    }
}

/// Small, private, crash-safe state files shared by every drip of this user.
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
        #if !os(WASI)
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw StateError("cannot lock \(lockPath): \(String(cString: strerror(errno)))") }
        }
        #endif
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

extension Icon {
    /// The icon as `--icon` takes it.
    var argument: String {
        switch self {
        case .none: return "none"
        case let .symbol(name): return name
        case let .image(path): return path
        case let .app(identifier): return Icon.appPrefix + identifier
        case let .mark(name): return AgentMark.prefix + name
        }
    }
}

extension CardColor {
    /// The color as `--color` takes it: a name, or `#rrggbb`.
    var argument: String {
        switch self {
        case let .system(name): return name.rawValue
        case let .rgb(red, green, blue):
            #if os(WASI)
            return "#" + [red, green, blue].map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
            #else
            return "#" + [red, green, blue].map { String(format: "%02x", $0) }.joined()
            #endif
        }
    }
}

extension Sound {
    /// The sound as `--sound` takes it: a name, a path, or `none`.
    var argument: String {
        switch self {
        case .none: return "none"
        case let .named(name): return name
        case let .file(path): return path
        }
    }
}
