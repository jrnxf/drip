#if !os(WASI)
import Foundation

/// An opt-in log of drip's decisions, for finding out why a card showed or did not: one line each
/// for what drip decided about an agent's card, with the inputs it decided on, and for how a click
/// went. Off unless `debug = true` is in the config or `DRIP_DEBUG=1` is set.
///
/// A line is `<time> <process> <event> <decision> key=value ...`, where `process` is the drip that
/// wrote it (`hook`, `follow` or `cli`). It holds what drip itself noticed (the frontmost app, how
/// long ago the keyboard or mouse was used, ids of panes and machines, the settings) and never what
/// an agent said: no card title or detail, prompt, tool input, command or path from a payload. A
/// session's id is cut to its first 8 characters.
///
/// Writing is best effort: a log that cannot be written never fails or holds up a hook.
public struct DebugLog {
    /// The drip that writes a line.
    public enum Process: String, Sendable {
        /// `drip hook`.
        case hook
        /// `drip follow`.
        case follow
        /// Any other drip, such as the one a hook hands its card to.
        case cli
    }

    /// The most the file holds. When a line takes it past this, the oldest lines go until about
    /// three quarters of it are left, so one trim serves many lines.
    public static let limit = 1024 * 1024

    /// The kind of drip this process is, for the lines that no `DebugLog` made by hand writes, such
    /// as the click on a card.
    public static var process = Process.cli

    public var path: String
    public var process: Process
    public var enabled: Bool
    public var now: () -> Date

    /// The log in `environment`'s state directory, on when the settings say so.
    public init(environment: [String: String], process: Process = DebugLog.process, now: @escaping () -> Date = Date.init) {
        self.init(
            path: Self.path(environment: environment), process: process,
            enabled: Self.isEnabled(environment: environment), now: now)
    }

    public init(path: String, process: Process, enabled: Bool, now: @escaping () -> Date = Date.init) {
        self.path = path
        self.process = process
        self.enabled = enabled
        self.now = now
    }

    /// `debug.log` in the state directory.
    public static func path(environment: [String: String]) -> String {
        (StateDirectory.path(environment: environment) as NSString).appendingPathComponent("debug.log")
    }

    /// `DRIP_DEBUG`, then the config's `debug`, then off. A setting that cannot be read counts as off:
    /// the log is not worth failing over.
    public static func isEnabled(environment: [String: String]) -> Bool {
        if let setting = (try? EnvironmentSettings.debug(environment: environment)) ?? nil { return setting }
        return (try? ConfigLoader.load(environment: environment))?.config.debug ?? false
    }

    /// Adds a line, when the log is on. A field with no value is left out.
    public func record(_ event: String, _ decision: String, _ fields: [(String, String?)] = []) {
        guard enabled else { return }
        let stamp = Self.timestamp(now())
        let pairs = fields.compactMap { field in field.1.map { "\(field.0)=\(Self.value($0))" } }
        append(([stamp, process.rawValue, event, decision] + pairs).joined(separator: " ") + "\n")
    }

    /// Adds a line to the log of this process's own environment, for the code that has no
    /// `Surroundings` to read it from, such as a click.
    public static func record(_ event: String, _ decision: String, _ fields: [(String, String?)] = []) {
        DebugLog(environment: ProcessInfo.processInfo.environment).record(event, decision, fields)
    }

    /// A session's id as the log keeps it: `claude:1a2b3c4d`, without the rest of the session id or
    /// the machine.
    public static func short(id: String) -> String {
        let session = id.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let colon = session.firstIndex(of: ":") else { return value(String(session.prefix(8))) }
        return value(String(session[..<colon]) + ":" + String(session[session.index(after: colon)...].prefix(8)))
    }

    /// `text` as one value in a line: as it is when it is plain, else in quotes, and never longer than
    /// 80 characters or across lines.
    static func value(_ text: String) -> String {
        let plain = text.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "._:@/+-%".unicodeScalars.contains($0)) }
        if plain, !text.isEmpty, text.count <= 80 { return text }
        let cleaned = String(String.UnicodeScalarView(
            text.unicodeScalars.prefix(80).filter { $0.value >= 0x20 && $0.value != 0x7f && $0 != "\"" && $0 != "\\" }))
        return "\"\(cleaned)\""
    }

    /// `2026-10-27T10:20:51.123+01:00`: the local time, to the millisecond.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func append(_ line: String) {
        _ = try? StateFiles.locked(path) {
            let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            // A file that was there before keeps no looser mode.
            fchmod(descriptor, 0o600)
            let bytes = Array(line.utf8)
            guard write(descriptor, bytes, bytes.count) == bytes.count else { return }
            var info = stat()
            if fstat(descriptor, &info) == 0, Int(info.st_size) > Self.limit { trim() }
        }
    }

    /// Drops the oldest lines, down to three quarters of the limit.
    private func trim() {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        var kept = data.suffix(Self.limit * 3 / 4)
        // The cut falls mid-line: start at the next one.
        if let newline = kept.firstIndex(of: UInt8(ascii: "\n")) { kept = kept[kept.index(after: newline)...] }
        try? StateFiles.write(String(decoding: kept, as: UTF8.self), toPath: path)
    }

    /// Everything in the log; empty when there is none.
    public static func contents(environment: [String: String]) -> String {
        guard let data = FileManager.default.contents(atPath: path(environment: environment)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Empties the log, keeping the file.
    public static func clear(environment: [String: String]) throws {
        let path = path(environment: environment)
        try StateFiles.locked(path) {
            guard FileManager.default.fileExists(atPath: path) else { return }
            try StateFiles.write("", toPath: path)
        }
    }
}

#endif

#if !os(WASI)
extension TerminalPane {
    /// The pane as the debug log names it: its multiplexer and id, such as `herdr:w1:p2`.
    public var debugName: String? {
        if let pane = tmuxPane { return "tmux:\(pane)" }
        if let pane = herdrPane { return "herdr:\(pane)" }
        if let pane = weztermPane { return "wezterm:\(pane)" }
        return herdrTab.map { "herdr-tab:\($0)" }
    }

    /// The question `Terminal.isShowing` asks about the pane, without the socket or the machine's
    /// address: `herdr pane get w1:p2`, or `tmux display-message`.
    public var debugQuery: String? {
        if let pane = herdrPane { return "herdr pane get \(pane)" }
        return tmuxPane == nil ? nil : "tmux display-message"
    }
}
#endif
