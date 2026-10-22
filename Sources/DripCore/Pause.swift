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
#endif

/// A pause from `drip pause`: until it ends, cards are held as they are while the screen is
/// locked, and show on the missed cards' way once it does. The end time is kept in the state
/// directory, so it holds for every drip and ends on its own.
public struct DripPause {
    /// How long `drip pause` pauses for when no duration is given.
    public static let defaultDuration: Double = 3600
    /// The longest pause, so a pause forgotten about never keeps drip quiet for good.
    public static let longest: Double = 24 * 3600

    public var path: String

    public init(path: String) {
        self.path = path
    }

    /// `pause` in the state directory.
    public init(environment: [String: String]) {
        self.init(path: (StateDirectory.path(environment: environment) as NSString).appendingPathComponent("pause"))
    }

    /// When the pause ends, or nil when drip is not paused at `now`.
    public func end(now: Date = Date()) -> Date? {
        guard let line = StateFiles.lines(atPath: path).first, let seconds = Double(line) else { return nil }
        let end = Date(timeIntervalSince1970: seconds)
        return end > now ? end : nil
    }

    /// Whether drip is paused at `now`.
    public func isPaused(now: Date = Date()) -> Bool {
        end(now: now) != nil
    }

    /// Pauses drip until `end`, replacing any pause that was set.
    public func pause(until end: Date) throws {
        try StateFiles.locked(path) {
            try StateFiles.write("\(end.timeIntervalSince1970)\n", toPath: path)
        }
    }

    /// Ends the pause now. Returns whether drip was paused at `now`.
    @discardableResult
    public func resume(now: Date = Date()) throws -> Bool {
        try StateFiles.locked(path) {
            let paused = isPaused(now: now)
            if unlink(path) != 0, errno != ENOENT {
                throw StateError("cannot remove \(path): \(String(cString: strerror(errno)))")
            }
            return paused
        }
    }

    /// A duration as `drip pause` takes it, in seconds: whole minutes and hours, such as `30m`,
    /// `2h` or `1h30m`. Nil for anything else.
    public static func duration(_ text: String) -> Double? {
        var total = 0.0
        var digits = ""
        var units: Set<Character> = []
        for character in text.lowercased() {
            if character.isASCII, character.isNumber {
                digits.append(character)
                continue
            }
            // Each unit once, hours before minutes, each after its number.
            guard let value = Double(digits), !units.contains(character), !(character == "h" && units.contains("m"))
            else { return nil }
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            default: return nil
            }
            units.insert(character)
            digits = ""
        }
        guard digits.isEmpty, !units.isEmpty, total > 0 else { return nil }
        return total
    }

    /// `1h`, `45m` or `1h 30m`: the time left, rounded up to the minute.
    public static func describe(seconds: Double) -> String {
        let minutes = Int((max(seconds, 0) / 60).rounded(.up))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(max(rest, 1))m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// What `drip pause` prints about a pause that ends at `end`: `drip is paused until 15:42
    /// (1h left)`, with `tomorrow` before a time that is not today.
    public static func status(end: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: end)
        // A pause is never longer than a day, so an end that is not today is tomorrow.
        let day = calendar.isDate(end, inSameDayAs: now) ? "" : "tomorrow "
        return "drip is paused until \(day)\(pad(parts.hour ?? 0)):\(pad(parts.minute ?? 0))"
            + " (\(describe(seconds: end.timeIntervalSince(now))) left)"
    }

    /// What a drip run in a terminal prints while drip is paused, so a pause is never forgotten:
    /// `drip is paused, 23m left (drip resume to unpause)`.
    public static func reminder(end: Date, now: Date = Date()) -> String {
        "drip is paused, \(describe(seconds: end.timeIntervalSince(now))) left (drip resume to unpause)"
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
