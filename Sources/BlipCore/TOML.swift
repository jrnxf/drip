/// A small TOML 1.0 parser that records the line of every key, so config errors can name it.
///
/// Supports the whole syntax: comments, bare, quoted and dotted keys, tables, arrays of tables,
/// inline tables, arrays, all four string forms, integers in every base, floats, booleans and
/// date-times. Date-times are kept as their source text, since no config key takes one.
public enum TOML {
    public static func parse(_ text: String) throws -> TOMLTable {
        var parser = TOMLParser(text)
        return try parser.parseDocument()
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
    case dateTime(String)
    case array([TOMLValue])
    case table(TOMLTable)

    /// The value's TOML type, for error messages.
    public var typeName: String {
        switch self {
        case .string: return "a string"
        case .integer: return "an integer"
        case .float: return "a float"
        case .boolean: return "a boolean"
        case .dateTime: return "a date-time"
        case .array: return "an array"
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

/// A table while it is being built. Classes, because headers and dotted keys reopen tables.
private final class TableNode {
    enum Origin {
        /// Created only as the parent of a header, such as `a` for `[a.b]`; a later `[a]` may define it.
        case implicit
        /// Defined by a `[header]`.
        case header
        /// Created by a dotted key such as `a.b = 1`.
        case dotted
        /// An inline `{ ... }` table, closed to any addition.
        case inline
    }

    var origin: Origin
    let line: Int
    var keys: [String] = []
    var entries: [String: Entry] = [:]

    init(origin: Origin, line: Int) {
        self.origin = origin
        self.line = line
    }

    func set(_ key: String, _ entry: Entry) {
        if entries[key] == nil { keys.append(key) }
        entries[key] = entry
    }

    var frozen: TOMLTable {
        var table = TOMLTable()
        for key in keys {
            guard let entry = entries[key] else { continue }
            table.set(key, entry.frozen)
        }
        return table
    }
}

private enum Entry {
    case value(TOMLValue, line: Int)
    case table(TableNode)
    case arrayOfTables([TableNode], line: Int)

    var frozen: TOMLItem {
        switch self {
        case let .value(value, line):
            return TOMLItem(value: value, line: line)
        case let .table(node):
            return TOMLItem(value: .table(node.frozen), line: node.line)
        case let .arrayOfTables(nodes, line):
            return TOMLItem(value: .array(nodes.map { .table($0.frozen) }), line: line)
        }
    }
}

private struct TOMLParser {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var line = 1

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    mutating func parseDocument() throws -> TOMLTable {
        let root = TableNode(origin: .header, line: 1)
        var current = root
        while true {
            skipWhitespace()
            guard let scalar = peek() else { break }
            switch scalar {
            case "#", "\n", "\r":
                try endOfLine()
            case "[":
                current = try parseHeader(root: root)
                try endOfLine()
            default:
                try parseKeyValue(into: current)
                try endOfLine()
            }
        }
        return root.frozen
    }

    // MARK: Tables

    private mutating func parseHeader(root: TableNode) throws -> TableNode {
        let headerLine = line
        advance()
        let isArray = peek() == "["
        if isArray { advance() }
        skipWhitespace()
        let keys = try parseKey()
        skipWhitespace()
        try expect("]", "expected ']' to close the table header")
        if isArray { try expect("]", "expected ']]' to close the array of tables header") }

        var table = root
        for key in keys.dropLast() {
            switch table.entries[key] {
            case nil:
                let child = TableNode(origin: .implicit, line: headerLine)
                table.set(key, .table(child))
                table = child
            case let .table(child) where child.origin != .inline:
                table = child
            case let .arrayOfTables(children, _):
                table = children[children.count - 1]
            default:
                throw error("'\(key)' is already a value, not a table", line: headerLine)
            }
        }
        let name = keys[keys.count - 1]
        let path = keys.joined(separator: ".")
        if isArray {
            let child = TableNode(origin: .header, line: headerLine)
            switch table.entries[name] {
            case nil:
                table.set(name, .arrayOfTables([child], line: headerLine))
            case let .arrayOfTables(children, line):
                table.set(name, .arrayOfTables(children + [child], line: line))
            default:
                throw error("'\(path)' is already defined and is not an array of tables", line: headerLine)
            }
            return child
        }
        switch table.entries[name] {
        case nil:
            let child = TableNode(origin: .header, line: headerLine)
            table.set(name, .table(child))
            return child
        case let .table(child) where child.origin == .implicit:
            child.origin = .header
            return child
        default:
            throw error("table '\(path)' is already defined", line: headerLine)
        }
    }

    private mutating func parseKeyValue(into table: TableNode) throws {
        let keyLine = line
        let keys = try parseKey()
        skipWhitespace()
        try expect("=", "expected '=' after the key")
        skipWhitespace()
        let value = try parseValue()

        var target = table
        for key in keys.dropLast() {
            switch target.entries[key] {
            case nil:
                let child = TableNode(origin: .dotted, line: keyLine)
                target.set(key, .table(child))
                target = child
            case let .table(child) where child.origin == .dotted:
                target = child
            default:
                throw error("cannot add keys to '\(key)' here", line: keyLine)
            }
        }
        let name = keys[keys.count - 1]
        guard target.entries[name] == nil else {
            throw error("'\(keys.joined(separator: "."))' is defined twice", line: keyLine)
        }
        if case let .table(inline) = value {
            target.set(name, .table(inline))
        } else if case let .value(plain) = value {
            target.set(name, .value(plain, line: keyLine))
        }
    }

    private enum Parsed {
        case value(TOMLValue)
        case table(TableNode)
    }

    // MARK: Keys

    private mutating func parseKey() throws -> [String] {
        var keys = [try parseSimpleKey()]
        while true {
            skipWhitespace()
            guard peek() == "." else { return keys }
            advance()
            skipWhitespace()
            keys.append(try parseSimpleKey())
        }
    }

    private mutating func parseSimpleKey() throws -> String {
        switch peek() {
        case "\""?:
            if peek(1) == "\"" && peek(2) == "\"" { throw error("a key cannot be a multi-line string") }
            return try parseBasicString()
        case "'"?:
            if peek(1) == "'" && peek(2) == "'" { throw error("a key cannot be a multi-line string") }
            return try parseLiteralString()
        default:
            var key = ""
            while let scalar = peek(), Self.isBareKeyScalar(scalar) {
                key.unicodeScalars.append(scalar)
                advance()
            }
            guard !key.isEmpty else { throw error("expected a key") }
            return key
        }
    }

    private static func isBareKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-": return true
        default: return false
        }
    }

    // MARK: Values

    private mutating func parseValue() throws -> Parsed {
        guard let scalar = peek() else { throw error("expected a value") }
        switch scalar {
        case "\"":
            if peek(1) == "\"" && peek(2) == "\"" { return .value(.string(try parseMultilineBasicString())) }
            return .value(.string(try parseBasicString()))
        case "'":
            if peek(1) == "'" && peek(2) == "'" { return .value(.string(try parseMultilineLiteralString())) }
            return .value(.string(try parseLiteralString()))
        case "[":
            return .value(.array(try parseArray()))
        case "{":
            return .table(try parseInlineTable())
        case "t" where matches("true"):
            index += 4
            return .value(.boolean(true))
        case "f" where matches("false"):
            index += 5
            return .value(.boolean(false))
        default:
            return .value(try parseNumberOrDateTime())
        }
    }

    private mutating func parseArray() throws -> [TOMLValue] {
        advance()
        var values: [TOMLValue] = []
        while true {
            try skipWhitespaceCommentsAndNewlines()
            if peek() == "]" {
                advance()
                return values
            }
            switch try parseValue() {
            case let .value(value): values.append(value)
            case let .table(table): values.append(.table(table.frozen))
            }
            try skipWhitespaceCommentsAndNewlines()
            if peek() == "," {
                advance()
            } else if peek() != "]" {
                throw error("expected ',' or ']' in the array")
            }
        }
    }

    private mutating func parseInlineTable() throws -> TableNode {
        let table = TableNode(origin: .dotted, line: line)
        advance()
        skipWhitespace()
        if peek() == "}" {
            advance()
            table.origin = .inline
            return table
        }
        while true {
            skipWhitespace()
            try parseKeyValue(into: table)
            skipWhitespace()
            if peek() == "," {
                advance()
            } else if peek() == "}" {
                advance()
                table.origin = .inline
                Self.closeDottedTables(in: table)
                return table
            } else {
                throw error("expected ',' or '}' in the inline table")
            }
        }
    }

    /// Dotted keys inside an inline table make tables that must be closed along with it.
    private static func closeDottedTables(in table: TableNode) {
        for case let .table(child) in table.entries.values {
            child.origin = .inline
            closeDottedTables(in: child)
        }
    }

    private mutating func parseNumberOrDateTime() throws -> TOMLValue {
        let start = index
        let tokenLine = line
        while let scalar = peek(), Self.isTokenScalar(scalar) { advance() }
        var token = String(String.UnicodeScalarView(scalars[start..<index]))
        // A date and a time may be separated by a space: 1979-05-27 07:32:00Z.
        if token.count == 10, Self.isDate(token), peek() == " ", let next = peek(1), ("0"..."9").contains(next) {
            advance()
            let timeStart = index
            while let scalar = peek(), Self.isTokenScalar(scalar) { advance() }
            token += " " + String(String.UnicodeScalarView(scalars[timeStart..<index]))
        }
        guard !token.isEmpty else { throw error("expected a value", line: tokenLine) }
        if Self.isDate(token) || Self.isTime(token) { return .dateTime(token) }
        if let value = Self.number(token) { return value }
        throw error("invalid value '\(token)'", line: tokenLine)
    }

    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "+", "-", ".", ":": return true
        default: return false
        }
    }

    private static func isDate(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        guard scalars.count >= 10 else { return false }
        return scalars[0..<4].allSatisfy(isDigit) && scalars[4] == "-" && scalars[7] == "-"
    }

    private static func isTime(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        guard scalars.count >= 8 else { return false }
        return scalars[0..<2].allSatisfy(isDigit) && scalars[2] == ":" && scalars[5] == ":"
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    private static func number(_ token: String) -> TOMLValue? {
        switch token {
        case "inf", "+inf": return .float(.infinity)
        case "-inf": return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where token.hasPrefix(prefix) {
            guard let digits = digitsWithoutUnderscores(String(token.dropFirst(2))) else { return nil }
            return Int64(digits, radix: radix).map(TOMLValue.integer)
        }
        guard let plain = digitsWithoutUnderscores(token) else { return nil }
        let unsigned = plain.hasPrefix("+") || plain.hasPrefix("-") ? String(plain.dropFirst()) : plain
        guard let first = unsigned.unicodeScalars.first, isDigit(first) else { return nil }
        if unsigned.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) {
            return isFloat(unsigned) ? Double(plain).map(TOMLValue.float) : nil
        }
        // No leading zeros, except for zero itself.
        guard unsigned == "0" || !unsigned.hasPrefix("0"), unsigned.allSatisfy(\.isASCII) else { return nil }
        return Int64(plain).map(TOMLValue.integer)
    }

    /// Removes underscores, which TOML allows only between two digits.
    private static func digitsWithoutUnderscores(_ token: String) -> String? {
        let scalars = Array(token.unicodeScalars)
        for (offset, scalar) in scalars.enumerated() where scalar == "_" {
            guard offset > 0, offset < scalars.count - 1,
                  scalars[offset - 1].properties.isASCIIHexDigit, scalars[offset + 1].properties.isASCIIHexDigit
            else { return nil }
        }
        return token.replacingUnderscores()
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
        while true {
            guard let scalar = peek(), scalar != "\n", scalar != "\r" else {
                throw error("unterminated string")
            }
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
    }

    private mutating func parseMultilineBasicString() throws -> String {
        index += 3
        skipNewline()
        var result = ""
        while true {
            guard let scalar = peek() else { throw error("unterminated multi-line string") }
            if scalar == "\"", peek(1) == "\"", peek(2) == "\"" {
                index += 3
                // Up to two quotes may sit right before the closing delimiter.
                for _ in 0..<2 where peek() == "\"" {
                    result.append("\"")
                    advance()
                }
                return result
            }
            if scalar == "\\" {
                advance()
                if lineEndingBackslash() { continue }
                result.unicodeScalars.append(try parseEscape())
                continue
            }
            if scalar == "\r", peek(1) == "\n" {
                advance()
                continue
            }
            if scalar != "\n" { try checkAllowedInString(scalar) }
            advance()
            result.unicodeScalars.append(scalar)
        }
    }

    private mutating func parseLiteralString() throws -> String {
        advance()
        var result = ""
        while true {
            guard let scalar = peek(), scalar != "\n", scalar != "\r" else {
                throw error("unterminated string")
            }
            advance()
            if scalar == "'" { return result }
            try checkAllowedInString(scalar)
            result.unicodeScalars.append(scalar)
        }
    }

    private mutating func parseMultilineLiteralString() throws -> String {
        index += 3
        skipNewline()
        var result = ""
        while true {
            guard let scalar = peek() else { throw error("unterminated multi-line string") }
            if scalar == "'", peek(1) == "'", peek(2) == "'" {
                index += 3
                for _ in 0..<2 where peek() == "'" {
                    result.append("'")
                    advance()
                }
                return result
            }
            if scalar == "\r", peek(1) == "\n" {
                advance()
                continue
            }
            if scalar != "\n" { try checkAllowedInString(scalar) }
            advance()
            result.unicodeScalars.append(scalar)
        }
    }

    /// After a backslash in a multi-line basic string: when only whitespace follows up to the end
    /// of the line, skips it and all whitespace and newlines after it.
    private mutating func lineEndingBackslash() -> Bool {
        var lookahead = index
        while lookahead < scalars.count, scalars[lookahead] == " " || scalars[lookahead] == "\t" {
            lookahead += 1
        }
        guard lookahead < scalars.count,
              scalars[lookahead] == "\n" || (scalars[lookahead] == "\r" && lookahead + 1 < scalars.count
                  && scalars[lookahead + 1] == "\n")
        else { return false }
        index = lookahead
        while let scalar = peek(), scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
            advance()
        }
        return true
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
        case "e": return "\u{1B}"
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

    // MARK: Whitespace and lines

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        index + offset < scalars.count ? scalars[index + offset] : nil
    }

    private func matches(_ word: String) -> Bool {
        let word = Array(word.unicodeScalars)
        guard index + word.count <= scalars.count, Array(scalars[index..<(index + word.count)]) == word else {
            return false
        }
        return peek(word.count).map { !Self.isTokenScalar($0) } ?? true
    }

    private mutating func advance() {
        if scalars[index] == "\n" { line += 1 }
        index += 1
    }

    private mutating func expect(_ scalar: Unicode.Scalar, _ message: String) throws {
        guard peek() == scalar else { throw error(message) }
        advance()
    }

    private mutating func skipWhitespace() {
        while let scalar = peek(), scalar == " " || scalar == "\t" { advance() }
    }

    private mutating func skipNewline() {
        if peek() == "\n" {
            advance()
        } else if peek() == "\r", peek(1) == "\n" {
            index += 1
            advance()
        }
    }

    private mutating func skipComment() throws {
        guard peek() == "#" else { return }
        while let scalar = peek(), scalar != "\n" {
            if scalar == "\r", peek(1) == "\n" { break }
            if scalar != "\t", scalar.value < 0x20 || scalar.value == 0x7F {
                throw error("control characters are not allowed in comments")
            }
            advance()
        }
    }

    private mutating func skipWhitespaceCommentsAndNewlines() throws {
        while true {
            skipWhitespace()
            try skipComment()
            guard let scalar = peek(), scalar == "\n" || scalar == "\r" else { return }
            if scalar == "\r", peek(1) != "\n" { throw error("a carriage return must be followed by a newline") }
            skipNewline()
        }
    }

    /// Requires the rest of the line to be empty or a comment, and consumes the line break.
    private mutating func endOfLine() throws {
        skipWhitespace()
        try skipComment()
        guard let scalar = peek() else { return }
        if scalar == "\n" || (scalar == "\r" && peek(1) == "\n") {
            skipNewline()
        } else {
            throw error("expected the end of the line")
        }
    }

    private func error(_ message: String, line: Int? = nil) -> TOMLError {
        TOMLError(line: line ?? self.line, message: message)
    }
}

private extension String {
    func replacingUnderscores() -> String {
        String(unicodeScalars.filter { $0 != "_" }.map(Character.init))
    }
}
