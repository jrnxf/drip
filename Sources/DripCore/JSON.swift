/// A JSON value that keeps an object's keys in the order they were written, so a settings file drip
/// adds its hooks to keeps the order its owner gave it, and a number as it was written, so it reads
/// back the same. Reads only strict JSON: no comments or trailing commas.
public enum JSONValue: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    /// The number's text, as written.
    case number(String)
    case bool(Bool)
    case null

    /// The members of an object, in order.
    public var members: [JSONMember]? {
        if case let .object(members) = self { return members }
        return nil
    }

    public var elements: [JSONValue]? {
        if case let .array(elements) = self { return elements }
        return nil
    }

    public var string: String? {
        if case let .string(string) = self { return string }
        return nil
    }

    /// An object's value for `key`: the last one, as JavaScript reads a key written twice.
    public subscript(key: String) -> JSONValue? {
        members?.last { $0.key == key }?.value
    }
}

public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// Why a text is not JSON, and on which line.
public struct JSONError: Error, Equatable, CustomStringConvertible {
    public var line: Int
    public var problem: String

    public init(line: Int, problem: String) {
        self.line = line
        self.problem = problem
    }

    public var description: String { "line \(line): \(problem)" }
}

extension JSONValue {
    /// The most arrays and objects inside one another that `init(parsing:)` reads, so a payload of
    /// a million brackets is an error rather than a crash. Settings files and hook payloads nest a
    /// few levels; WebAssembly's stack runs out a few hundred levels down.
    static let depthLimit = 64

    /// Reads one JSON value, with only whitespace around it.
    public init(parsing text: String) throws {
        var parser = JSONParser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        if parser.index < parser.bytes.count { throw parser.error("unexpected text after the value") }
        self = value
    }

    /// The value as `JSON.stringify(value, null, indent)` writes it: each member and element on a line
    /// of its own, indented by `indent` per level, and empty objects and arrays as `{}` and `[]`.
    public func formatted(indent: String = "  ") -> String {
        var text = ""
        write(to: &text, indent: indent, level: 0)
        return text
    }

    private func write(to text: inout String, indent: String, level: Int) {
        let inner = String(repeating: indent, count: level + 1)
        switch self {
        case let .object(members):
            guard !members.isEmpty else { text += "{}"; return }
            text += "{\n"
            for (index, member) in members.enumerated() {
                text += inner
                Self.quote(member.key, into: &text)
                text += ": "
                member.value.write(to: &text, indent: indent, level: level + 1)
                text += index < members.count - 1 ? ",\n" : "\n"
            }
            text += String(repeating: indent, count: level) + "}"
        case let .array(elements):
            guard !elements.isEmpty else { text += "[]"; return }
            text += "[\n"
            for (index, element) in elements.enumerated() {
                text += inner
                element.write(to: &text, indent: indent, level: level + 1)
                text += index < elements.count - 1 ? ",\n" : "\n"
            }
            text += String(repeating: indent, count: level) + "]"
        case let .string(string): Self.quote(string, into: &text)
        case let .number(number): text += number
        case let .bool(bool): text += bool ? "true" : "false"
        case .null: text += "null"
        }
    }

    /// A string as JSON writes it: quotes, backslashes and control characters escaped, the rest as is.
    private static func quote(_ string: String, into text: inout String) {
        text += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case "\u{08}": text += "\\b"
            case "\u{0C}": text += "\\f"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                text += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: text.unicodeScalars.append(scalar)
            }
        }
        text += "\""
    }

    /// The indent a JSON text uses: the leading whitespace of its first indented line, else two spaces.
    public static func indent(of text: String) -> String {
        for line in text.split(separator: "\n").dropFirst() {
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            if !leading.isEmpty { return String(leading) }
        }
        return "  "
    }
}

/// Reads JSON from UTF-8 bytes, as RFC 8259 writes it.
private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    func error(_ problem: String) -> JSONError {
        JSONError(line: bytes[..<min(index, bytes.count)].reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }, problem: problem)
    }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    mutating func value(depth: Int) throws -> JSONValue {
        guard index < bytes.count else { throw error("unexpected end of text") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object(depth: depth + 1)
        case UInt8(ascii: "["): return try array(depth: depth + 1)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
        case UInt8(ascii: "/"): throw error("comments are not JSON")
        default: throw error("expected a value")
        }
    }

    mutating func object(depth: Int) throws -> JSONValue {
        if depth > JSONValue.depthLimit { throw error("nested too deeply") }
        index += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                if index < bytes.count, bytes[index] == UInt8(ascii: "/") { throw error("comments are not JSON") }
                throw error(members.isEmpty ? "expected a key in quotes" : "expected a key in quotes after the comma")
            }
            let key = try string()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected : after the key") }
            index += 1
            skipWhitespace()
            members.append(JSONMember(key, try value(depth: depth)))
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end of text in an object") }
            switch bytes[index] {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(members)
            default: throw error("expected , or } in an object")
            }
        }
    }

    mutating func array(depth: Int) throws -> JSONValue {
        if depth > JSONValue.depthLimit { throw error("nested too deeply") }
        index += 1
        var elements: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try value(depth: depth))
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end of text in an array") }
            switch bytes[index] {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(elements)
            default: throw error("expected , or ] in an array")
            }
        }
    }

    mutating func literal(_ word: String) throws {
        let word = Array(word.utf8)
        guard bytes.count - index >= word.count, Array(bytes[index..<index + word.count]) == word else {
            throw error("expected a value")
        }
        index += word.count
    }

    mutating func number() throws -> String {
        let start = index
        func digits() -> Int {
            let first = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            return index - first
        }
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        if index < bytes.count, bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if digits() == 0 {
            throw error("expected a digit")
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            if digits() == 0 { throw error("expected a digit after the decimal point") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            if digits() == 0 { throw error("expected a digit in the exponent") }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    mutating func string() throws -> String {
        index += 1
        var start = index
        var text = ""
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                text += String(decoding: bytes[start..<index], as: UTF8.self)
                index += 1
                return text
            }
            if byte < 0x20 { throw error("a control character in a string must be escaped") }
            guard byte == UInt8(ascii: "\\") else {
                index += 1
                continue
            }
            text += String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            guard index < bytes.count else { break }
            switch bytes[index] {
            case UInt8(ascii: "\""): text += "\""
            case UInt8(ascii: "\\"): text += "\\"
            case UInt8(ascii: "/"): text += "/"
            case UInt8(ascii: "b"): text += "\u{08}"
            case UInt8(ascii: "f"): text += "\u{0C}"
            case UInt8(ascii: "n"): text += "\n"
            case UInt8(ascii: "r"): text += "\r"
            case UInt8(ascii: "t"): text += "\t"
            case UInt8(ascii: "u"):
                var code = try hex()
                if (0xD800...0xDBFF).contains(code), bytes.count - index > 6,
                   bytes[index + 1] == UInt8(ascii: "\\"), bytes[index + 2] == UInt8(ascii: "u") {
                    // A surrogate pair: two escapes for one character.
                    let mark = index
                    index += 2
                    let low = try hex()
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = mark
                    }
                }
                // A lone surrogate is no character: it reads as the replacement character.
                text.unicodeScalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
            default: throw error("unknown escape in a string")
            }
            index += 1
            start = index
        }
        throw error("unexpected end of text in a string")
    }

    /// The four hex digits after `\u`, leaving `index` on the last.
    mutating func hex() throws -> UInt32 {
        guard bytes.count - index > 4 else { throw error("expected 4 hex digits after \\u") }
        var code: UInt32 = 0
        for _ in 0..<4 {
            index += 1
            guard let digit = Character(Unicode.Scalar(bytes[index])).hexDigitValue else {
                throw error("expected 4 hex digits after \\u")
            }
            code = code * 16 + UInt32(digit)
        }
        return code
    }
}
