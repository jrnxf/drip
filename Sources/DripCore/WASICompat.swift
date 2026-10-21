// WebAssembly builds use FoundationEssentials instead of Foundation, which would bring ICU's data
// and every corelibs class with it. This fills in the few pieces of Foundation DripCore uses that
// FoundationEssentials does not have.
#if os(WASI)
import FoundationEssentials

public typealias CGFloat = Double

public struct CGPoint: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
}

public struct CGSize: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public init(width: CGFloat, height: CGFloat) { self.width = width; self.height = height }
    public static let zero = CGSize(width: 0, height: 0)
}

public struct CGRect: Equatable, Sendable {
    public var origin: CGPoint
    public var size: CGSize
    public init(origin: CGPoint, size: CGSize) { self.origin = origin; self.size = size }
    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.init(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }
    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }
    public var minX: CGFloat { origin.x }
    public var minY: CGFloat { origin.y }
    public var maxX: CGFloat { origin.x + size.width }
    public var maxY: CGFloat { origin.y + size.height }
    public var midX: CGFloat { origin.x + size.width / 2 }
    public var midY: CGFloat { origin.y + size.height / 2 }
}

/// Only the sets DripCore trims.
struct CharacterSet: Sendable {
    let contains: @Sendable (Character) -> Bool
    static let whitespaces = CharacterSet { $0.isWhitespace && !$0.isNewline }
    static let whitespacesAndNewlines = CharacterSet { $0.isWhitespace }
}

extension CharacterSet {
    init(charactersIn characters: String) {
        self.init { characters.contains($0) }
    }
}

extension StringProtocol {
    func trimmingCharacters(in set: CharacterSet) -> String {
        guard let first = firstIndex(where: { !set.contains($0) }) else { return "" }
        let last = lastIndex(where: { !set.contains($0) })!
        return String(self[first...last])
    }

    func range(of other: String) -> Range<Index>? {
        firstRange(of: other)
    }
}

/// Paths are plain strings here: `(path as NSString).deletingLastPathComponent` reads the same.
typealias NSString = String

extension String {
    var lastPathComponent: String {
        split(separator: "/").last.map(String.init) ?? (hasPrefix("/") ? "/" : "")
    }

    var deletingLastPathComponent: String {
        let parts = split(separator: "/")
        guard parts.count > 1 else { return hasPrefix("/") ? "/" : "" }
        return (hasPrefix("/") ? "/" : "") + parts.dropLast().joined(separator: "/")
    }

    func appendingPathComponent(_ component: String) -> String {
        isEmpty ? component : hasSuffix("/") ? self + component : self + "/" + component
    }

    var expandingTildeInPath: String {
        guard hasPrefix("~") else { return self }
        return NSHomeDirectory().appendingPathComponent(String(dropFirst().drop { $0 == "/" }))
    }

    /// Drops `.` and empty components and resolves `..`.
    var standardizingPath: String {
        var parts: [Substring] = []
        for part in split(separator: "/") where part != "." {
            if part == "..", !parts.isEmpty { parts.removeLast() } else if part != ".." { parts.append(part) }
        }
        return (hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
    }
}

extension Error {
    var localizedDescription: String { "\(self)" }
}

func NSTemporaryDirectory() -> String {
    ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
}

func NSHomeDirectory() -> String {
    ProcessInfo.processInfo.environment["HOME"] ?? "/"
}
#endif
