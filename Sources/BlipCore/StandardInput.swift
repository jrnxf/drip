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
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        return read(from: STDIN_FILENO, limit: limit)
    }

    /// Reads up to `limit` bytes or end of file from a file descriptor, as lossy UTF-8.
    public static func read(from descriptor: Int32, limit: Int) -> String? {
        var bytes = [UInt8](repeating: 0, count: limit)
        var count = 0
        while count < limit {
            let result = bytes.withUnsafeMutableBytes { buffer in
                #if canImport(Darwin)
                Darwin.read(descriptor, buffer.baseAddress! + count, limit - count)
                #else
                Glibc.read(descriptor, buffer.baseAddress! + count, limit - count)
                #endif
            }
            if result > 0 {
                count += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        guard count > 0 else { return nil }
        // A cut at the limit can end inside a UTF-8 sequence; drop the replacement it would become.
        var text = String(decoding: bytes[..<count], as: UTF8.self)
        if count == limit, text.last == "\u{FFFD}" { text.removeLast() }
        return text
    }
}
