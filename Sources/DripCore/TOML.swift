/// A parser for the part of TOML that config.toml uses. It records the line of every key, so config
/// errors can name it.
///
/// Supports comments, `key = value` with bare keys, dotted keys such as `preset.ok.sound = "Hero"`,
/// table headers such as `[preset.ok]`, single-line inline tables such as `{ sound = "Hero" }`, and
/// values that are single-line basic or literal strings, decimal integers, floats and booleans.
/// Tables follow TOML 1.0: a header, a dotted key or an inline table cannot redefine a table that
/// another one made, and an inline table is closed. Any other TOML syntax is an error naming its line.
public enum TOML {
    /// The most keys a table header has.
    public static let headerDepth = 2

    /// The most keys a dotted key has, and the most inline tables inside each other. Deeper input is
    /// an error, since it would exhaust the stack.
    public static let nestingDepth = 8

    public static func parse(_ text: String) throws -> TOMLTable {
        let root = TableNode(line: 1, origin: .header)
        var current = root
        for (offset, scalars) in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            var parser = LineParser(scalars, line: offset + 1)
            parser.skipWhitespace()
            switch parser.peek() {
            case nil, "#"?:
                continue
            case "["?:
                current = try parser.parseHeader(root: root)
            default:
                try parser.parseKeyValue(into: current, depth: 0)
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
    /// What made the table, which decides what may change it later.
    enum Origin {
        /// Made as the parent of a header's table. A header may still define it, once.
        case implicit
        /// Defined by a `[header]`.
        case header
        /// Made by a dotted key. Only dotted keys of the same section add to it.
        case dotted
        /// An inline table, which nothing extends.
        case inline
    }

    let line: Int
    var origin: Origin
    var keys: [String] = []
    var entries: [String: Entry] = [:]

    init(line: Int, origin: Origin) {
        self.line = line
        self.origin = origin
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

    mutating func parseHeader(root: TableNode) throws -> TableNode {
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
        var table = root
        for (offset, key) in path.enumerated() {
            let isLast = offset == path.count - 1
            switch table.entries[key] {
            case nil:
                let child = TableNode(line: line, origin: isLast ? .header : .implicit)
                table.set(key, .table(child))
                table = child
            case let .table(child)?:
                if child.origin == .inline {
                    throw error("'\(key)' is an inline table, which cannot be extended")
                }
                if isLast {
                    guard child.origin == .implicit else {
                        throw error("table '\(path.joined(separator: "."))' is already defined")
                    }
                    child.origin = .header
                }
                table = child
            case .value?:
                throw error("'\(key)' is already a value, not a table")
            }
        }
        return table
    }

    /// Parses `key = value` or `a.b.c = value` and adds it to `table`. `depth` counts the inline
    /// tables around this one.
    mutating func parseKeyValue(into table: TableNode, depth: Int) throws {
        var path = [try parseKey()]
        skipWhitespace()
        while consume(".") {
            if path.count == TOML.nestingDepth {
                throw error("dotted keys have at most \(TOML.nestingDepth) keys")
            }
            skipWhitespace()
            path.append(try parseKey())
            skipWhitespace()
        }
        guard consume("=") else { throw error("expected '=' after the key") }
        skipWhitespace()
        var parent = table
        for (offset, key) in path.dropLast().enumerated() {
            let name = path[0...offset].joined(separator: ".")
            switch parent.entries[key] {
            case nil:
                let child = TableNode(line: line, origin: .dotted)
                parent.set(key, .table(child))
                parent = child
            case let .table(child)? where child.origin == .dotted:
                parent = child
            case .table?:
                throw error("'\(name)' is already defined as a table, so a dotted key cannot add to it")
            case .value?:
                throw error("'\(name)' is already a value, not a table")
            }
        }
        let entry: Entry
        if peek() == "{" {
            entry = .table(try parseInlineTable(depth: depth + 1))
        } else {
            entry = .value(TOMLItem(value: try parseValue(), line: line))
        }
        let key = path[path.count - 1]
        guard parent.entries[key] == nil else { throw error("'\(path.joined(separator: "."))' is defined twice") }
        parent.set(key, entry)
    }

    /// Parses `{ key = value, ... }` on this line, with no trailing comma.
    private mutating func parseInlineTable(depth: Int) throws -> TableNode {
        if depth > TOML.nestingDepth {
            throw error("inline tables nest at most \(TOML.nestingDepth) deep")
        }
        advance()
        let table = TableNode(line: line, origin: .inline)
        skipWhitespace()
        if consume("}") { return table }
        while true {
            skipWhitespace()
            try parseKeyValue(into: table, depth: depth)
            skipWhitespace()
            if consume("}") { return table }
            guard consume(",") else {
                throw error(peek() == nil ? "unterminated inline table; it must end with '}' on the same line"
                                          : "expected ',' or '}' in the inline table")
            }
            skipWhitespace()
            if peek() == "}" { throw error("a trailing comma is not allowed in an inline table") }
            if peek() == nil { throw error("unterminated inline table; it must end with '}' on the same line") }
        }
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
        case "#"? where peek(1).map({ $0.properties.isASCIIHexDigit }) == true:
            // color = #a78bfa: the # starts a comment.
            throw error("expected a value; a color needs quotes, as in \"#a78bfa\", since # starts a comment")
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
        if !["inf", "nan"].contains(token),
           token.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic || "-_.".unicodeScalars.contains($0) }) {
            // Such as size = large: a word without its quotes.
            throw error("invalid value '\(token)'; a string needs quotes: \"\(token)\"")
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
