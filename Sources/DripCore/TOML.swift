/// A parser for the part of TOML that config.toml uses. It records the line of every key, so config
/// errors can name it.
///
/// Supports comments, `key = value` with bare keys, table headers such as `[preset.ok]`, and values
/// that are single-line basic or literal strings, decimal integers, floats and booleans. Any other
/// TOML syntax is an error naming its line.
public enum TOML {
    /// The most keys a table header has.
    public static let headerDepth = 2

    public static func parse(_ text: String) throws -> TOMLTable {
        let root = TableNode(line: 1)
        var current = root
        var headers: Set<[String]> = []
        for (offset, scalars) in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            var parser = LineParser(scalars, line: offset + 1)
            parser.skipWhitespace()
            switch parser.peek() {
            case nil, "#"?:
                continue
            case "["?:
                current = try parser.parseHeader(root: root, headers: &headers)
            default:
                try parser.parseKeyValue(into: current)
            }
            try parser.endOfLine()
        }
        return root.frozen
    }
}

public struct TOMLError: Error, Equatable, CustomStringConvertible {
    public var line: Int
    public var message: String

    public var description: String { "line \(line): \(message)" }
}

public indirect enum TOMLValue: Equatable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    case table(TOMLTable)

    /// The value's TOML type, for error messages.
    public var typeName: String {
        switch self {
        case .string: return "a string"
        case .integer: return "an integer"
        case .float: return "a float"
        case .boolean: return "a boolean"
        case .table: return "a table"
        }
    }
}

/// A key's value and the line the key is on.
public struct TOMLItem: Equatable {
    public var value: TOMLValue
    public var line: Int

    public init(value: TOMLValue, line: Int) {
        self.value = value
        self.line = line
    }
}

/// A table with its keys in source order.
public struct TOMLTable: Equatable {
    public private(set) var keys: [String] = []
    private var items: [String: TOMLItem] = [:]

    public init() {}

    public subscript(key: String) -> TOMLItem? {
        items[key]
    }

    mutating func set(_ key: String, _ item: TOMLItem) {
        if items[key] == nil { keys.append(key) }
        items[key] = item
    }
}

// MARK: - Parsing

/// A table while it is being built. A class, because a later header can add to a parent table.
private final class TableNode {
    let line: Int
    var keys: [String] = []
    var entries: [String: Entry] = [:]

    init(line: Int) {
        self.line = line
    }

    func set(_ key: String, _ entry: Entry) {
        if entries[key] == nil { keys.append(key) }
        entries[key] = entry
    }

    var frozen: TOMLTable {
        var table = TOMLTable()
        for key in keys {
            switch entries[key] {
            case let .value(item)?: table.set(key, item)
            case let .table(node)?: table.set(key, TOMLItem(value: .table(node.frozen), line: node.line))
            case nil: break
            }
        }
        return table
    }
}

private enum Entry {
    case value(TOMLItem)
    case table(TableNode)
}

/// Parses one line, without its line break.
private struct LineParser {
    private let scalars: [Unicode.Scalar]
    private let line: Int
    private var index = 0

    init(_ scalars: Substring.UnicodeScalarView, line: Int) {
        var scalars = Array(scalars)
        if scalars.last == "\r" { scalars.removeLast() }
        self.scalars = scalars
        self.line = line
    }

    // MARK: Tables and keys

    mutating func parseHeader(root: TableNode, headers: inout Set<[String]>) throws -> TableNode {
        advance()
        if peek() == "[" { throw error("arrays of tables are not supported") }
        var path: [String] = []
        repeat {
            // config.toml's deepest table is [preset.NAME]; a deeper one is a mistake, and one
            // thousands of keys deep would exhaust the stack.
            if path.count == TOML.headerDepth {
                throw error("table headers have at most \(TOML.headerDepth) keys, such as [preset.ok]")
            }
            skipWhitespace()
            path.append(try parseKey())
            skipWhitespace()
        } while consume(".")
        guard consume("]") else { throw error("expected ']' to close the table header") }
        guard headers.insert(path).inserted else {
            throw error("table '\(path.joined(separator: "."))' is already defined")
        }
        var table = root
        for key in path {
            switch table.entries[key] {
            case nil:
                let child = TableNode(line: line)
                table.set(key, .table(child))
                table = child
            case let .table(child)?:
                table = child
            case .value?:
                throw error("'\(key)' is already a value, not a table")
            }
        }
        return table
    }

    mutating func parseKeyValue(into table: TableNode) throws {
        let key = try parseKey()
        skipWhitespace()
        if peek() == "." { throw error("dotted keys are not supported; use a [table] header") }
        guard consume("=") else { throw error("expected '=' after the key") }
        skipWhitespace()
        let value = try parseValue()
        guard table.entries[key] == nil else { throw error("'\(key)' is defined twice") }
        table.set(key, .value(TOMLItem(value: value, line: line)))
    }

    private mutating func parseKey() throws -> String {
        if peek() == "\"" || peek() == "'" { throw error("quoted keys are not supported") }
        var key = ""
        while let scalar = peek(), Self.isBareKeyScalar(scalar) {
            key.unicodeScalars.append(scalar)
            advance()
        }
        guard !key.isEmpty else { throw error("expected a key") }
        return key
    }

    private static func isBareKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-": return true
        default: return false
        }
    }

    // MARK: Values

    private mutating func parseValue() throws -> TOMLValue {
        switch peek() {
        case "\""?:
            if peek(1) == "\"" && peek(2) == "\"" { throw error("multi-line strings are not supported") }
            return .string(try parseBasicString())
        case "'"?:
            if peek(1) == "'" && peek(2) == "'" { throw error("multi-line strings are not supported") }
            return .string(try parseLiteralString())
        case "["?:
            throw error("arrays are not supported")
        case "{"?:
            throw error("inline tables are not supported")
        default:
            return try parseToken()
        }
    }

    private mutating func parseToken() throws -> TOMLValue {
        var token = ""
        while let scalar = peek(), Self.isTokenScalar(scalar) {
            token.unicodeScalars.append(scalar)
            advance()
        }
        switch token {
        case "": throw error("expected a value")
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        default: break
        }
        if let number = Self.number(token) { return number }
        if token.contains(":") || Self.isDate(token) { throw error("date-times are not supported") }
        if ["0x", "0o", "0b"].contains(where: { token.hasPrefix($0) }) {
            throw error("hexadecimal, octal and binary integers are not supported")
        }
        throw error("invalid value '\(token)'")
    }

    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "+", "-", ".", ":": return true
        default: return false
        }
    }

    private static func isDate(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        return scalars.count >= 5 && scalars[0..<4].allSatisfy(isDigit) && scalars[4] == "-"
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    /// A decimal integer or float, with an optional sign and underscores between digits.
    private static func number(_ token: String) -> TOMLValue? {
        let scalars = Array(token.unicodeScalars)
        for (offset, scalar) in scalars.enumerated() where scalar == "_" {
            guard offset > 0, offset < scalars.count - 1, isDigit(scalars[offset - 1]), isDigit(scalars[offset + 1])
            else { return nil }
        }
        let plain = String(String.UnicodeScalarView(scalars.filter { $0 != "_" }))
        let unsigned = plain.hasPrefix("+") || plain.hasPrefix("-") ? String(plain.dropFirst()) : plain
        guard let first = unsigned.unicodeScalars.first, isDigit(first) else { return nil }
        if unsigned.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) {
            return isFloat(unsigned) ? Double(plain).map(TOMLValue.float) : nil
        }
        // No leading zeros, except for zero itself.
        guard unsigned == "0" || !unsigned.hasPrefix("0"), unsigned.unicodeScalars.allSatisfy(isDigit) else {
            return nil
        }
        return Int64(plain).map(TOMLValue.integer)
    }

    /// An unsigned decimal float: digits, then a fraction, an exponent or both, each with digits.
    private static func isFloat(_ text: String) -> Bool {
        var scalars = Array(text.unicodeScalars)[...]
        func digits() -> Int {
            var count = 0
            while let scalar = scalars.first, isDigit(scalar) {
                scalars.removeFirst()
                count += 1
            }
            return count
        }
        let integer = scalars
        guard digits() > 0 else { return false }
        if integer.count > 1, integer.first == "0", isDigit(integer[integer.startIndex + 1]) { return false }
        if scalars.first == "." {
            scalars.removeFirst()
            guard digits() > 0 else { return false }
        }
        if scalars.first == "e" || scalars.first == "E" {
            scalars.removeFirst()
            if scalars.first == "+" || scalars.first == "-" { scalars.removeFirst() }
            guard digits() > 0 else { return false }
        }
        return scalars.isEmpty
    }

    // MARK: Strings

    private mutating func parseBasicString() throws -> String {
        advance()
        var result = ""
        while let scalar = peek() {
            advance()
            switch scalar {
            case "\"":
                return result
            case "\\":
                result.unicodeScalars.append(try parseEscape())
            default:
                try checkAllowedInString(scalar)
                result.unicodeScalars.append(scalar)
            }
        }
        throw error("unterminated string")
    }

    private mutating func parseLiteralString() throws -> String {
        advance()
        var result = ""
        while let scalar = peek() {
            advance()
            if scalar == "'" { return result }
            try checkAllowedInString(scalar)
            result.unicodeScalars.append(scalar)
        }
        throw error("unterminated string")
    }

    private mutating func parseEscape() throws -> Unicode.Scalar {
        guard let scalar = peek() else { throw error("unterminated string") }
        advance()
        switch scalar {
        case "b": return "\u{08}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "u": return try parseUnicodeEscape(length: 4)
        case "U": return try parseUnicodeEscape(length: 8)
        default: throw error("invalid escape '\\\(scalar)'")
        }
    }

    private mutating func parseUnicodeEscape(length: Int) throws -> Unicode.Scalar {
        guard index + length <= scalars.count else { throw error("unterminated unicode escape") }
        let hex = String(String.UnicodeScalarView(scalars[index..<(index + length)]))
        guard hex.unicodeScalars.allSatisfy(\.properties.isASCIIHexDigit),
              let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value)
        else { throw error("invalid unicode escape '\(hex)'") }
        index += length
        return scalar
    }

    private func checkAllowedInString(_ scalar: Unicode.Scalar) throws {
        if scalar != "\t", scalar.value < 0x20 || scalar.value == 0x7F {
            throw error("control characters are not allowed in strings")
        }
    }

    // MARK: Whitespace

    func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        index + offset < scalars.count ? scalars[index + offset] : nil
    }

    private mutating func advance() {
        index += 1
    }

    private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        guard peek() == scalar else { return false }
        advance()
        return true
    }

    mutating func skipWhitespace() {
        while let scalar = peek(), scalar == " " || scalar == "\t" { advance() }
    }

    /// Requires the rest of the line to be empty or a comment.
    mutating func endOfLine() throws {
        skipWhitespace()
        guard peek() == nil || peek() == "#" else { throw error("expected the end of the line") }
    }

    private func error(_ message: String) -> TOMLError {
        TOMLError(line: line, message: message)
    }
}
