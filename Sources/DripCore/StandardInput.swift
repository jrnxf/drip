#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum StandardInput {
    /// The most stdin may supply.
    public static let limit = 64 * 1024

    /// Reads stdin when it is not a terminal, up to `limit` bytes or end of file. Returns nil for
    /// a terminal or when there is no data.
    public static func read() -> String? {
        read(limit: limit)
    }

    /// Reads stdin when it is not a terminal, up to `limit` bytes or end of file.
    public static func read(limit: Int) -> String? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        return read(from: STDIN_FILENO, limit: limit)
    }

    /// Reads a file descriptor to end of file, as lossy UTF-8, keeping the first `limit` bytes.
    /// The rest is read and dropped, so the command writing it, as in `./backup.sh | drip ok`, is
    /// never cut short by a closed pipe.
    public static func read(from descriptor: Int32, limit: Int) -> String? {
        var bytes = [UInt8](repeating: 0, count: limit)
        var count = 0
        var discard = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let result: Int
            if count < limit {
                result = bytes.withUnsafeMutableBytes { readSome(descriptor, $0.baseAddress! + count, limit - count) }
                if result > 0 { count += result }
            } else {
                result = discard.withUnsafeMutableBytes { readSome(descriptor, $0.baseAddress!, $0.count) }
            }
            if result < 0, errno == EINTR { continue }
            if result <= 0 { break }
        }
        guard count > 0 else { return nil }
        // A cut at the limit can end inside a UTF-8 sequence; drop the replacement it would become.
        var text = String(decoding: bytes[..<count], as: UTF8.self)
        if count == limit, text.last == "\u{FFFD}" { text.removeLast() }
        return text
    }

    private static func readSome(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(descriptor, buffer, size)
        #else
        Glibc.read(descriptor, buffer, size)
        #endif
    }
}
