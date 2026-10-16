import BlipCore
import XCTest

final class TOMLTests: XCTestCase {
    func testScalarsAndLines() throws {
        let table = try TOML.parse("""
            # a comment
            seconds  = 4.5
            position = "bottom"          # trailing comment
            count = 3
            sound    = false
            """)
        XCTAssertEqual(table.keys, ["seconds", "position", "count", "sound"])
        XCTAssertEqual(table["seconds"], TOMLItem(value: .float(4.5), line: 2))
        XCTAssertEqual(table["position"], TOMLItem(value: .string("bottom"), line: 3))
        XCTAssertEqual(table["count"], TOMLItem(value: .integer(3), line: 4))
        XCTAssertEqual(table["sound"], TOMLItem(value: .boolean(false), line: 5))
    }

    func testTables() throws {
        let table = try TOML.parse("""
            [preset.ok]
            sound = "Hero"

            [preset.deploy]
            icon  = "paperplane.fill"
            seconds = 6
            """)
        guard case let .table(presets)? = table["preset"]?.value,
              case let .table(ok)? = presets["ok"]?.value,
              case let .table(deploy)? = presets["deploy"]?.value
        else { return XCTFail("\(table)") }
        XCTAssertEqual(presets.keys, ["ok", "deploy"])
        XCTAssertEqual(presets["ok"]?.line, 1)
        XCTAssertEqual(presets["deploy"]?.line, 4)
        XCTAssertEqual(ok["sound"], TOMLItem(value: .string("Hero"), line: 2))
        XCTAssertEqual(deploy["seconds"], TOMLItem(value: .integer(6), line: 6))
    }

    func testDottedKeysInlineTablesAndQuotedKeys() throws {
        let table = try TOML.parse("""
            preset.ok.sound = "Hero"
            preset.warn = { sound = "Ping", seconds = 2 }
            "quoted key" = 1
            'literal key' = 2
            a . b = 3
            """)
        guard case let .table(presets)? = table["preset"]?.value,
              case let .table(ok)? = presets["ok"]?.value,
              case let .table(warn)? = presets["warn"]?.value
        else { return XCTFail("\(table)") }
        XCTAssertEqual(ok["sound"]?.value, .string("Hero"))
        XCTAssertEqual(warn["seconds"], TOMLItem(value: .integer(2), line: 2))
        XCTAssertEqual(table["quoted key"]?.value, .integer(1))
        XCTAssertEqual(table["literal key"]?.value, .integer(2))
        guard case let .table(a)? = table["a"]?.value else { return XCTFail() }
        XCTAssertEqual(a["b"]?.value, .integer(3))
    }

    func testStrings() throws {
        let table = try TOML.parse(#"""
            basic = "tab\there \"q\" \u00e9 \U0001F389 back\\slash"
            literal = 'C:\path\no escapes'
            multi = """
            one
            two"""
            folded = """\
                   joined \
                   line"""
            quotes = """a ""quoted"" b"""""
            raw = '''
            first
            'second' '''
            empty = ""
            """#)
        XCTAssertEqual(table["basic"]?.value, .string("tab\there \"q\" é 🎉 back\\slash"))
        XCTAssertEqual(table["literal"]?.value, .string(#"C:\path\no escapes"#))
        XCTAssertEqual(table["multi"]?.value, .string("one\ntwo"))
        XCTAssertEqual(table["folded"]?.value, .string("joined line"))
        XCTAssertEqual(table["quotes"]?.value, .string("a \"\"quoted\"\" b\"\""))
        XCTAssertEqual(table["raw"]?.value, .string("first\n'second' "))
        XCTAssertEqual(table["empty"]?.value, .string(""))
        XCTAssertEqual(table["raw"]?.line, 10)
    }

    func testNumbers() throws {
        let table = try TOML.parse("""
            a = +42
            b = -17
            c = 1_000
            d = 0xDEAD_beef
            e = 0o755
            f = 0b1101
            g = 3.1415
            h = -0.01
            i = 5e+22
            j = 6.626e-34
            k = inf
            l = -inf
            m = 0
            n = 1E3
            """)
        XCTAssertEqual(table["a"]?.value, .integer(42))
        XCTAssertEqual(table["b"]?.value, .integer(-17))
        XCTAssertEqual(table["c"]?.value, .integer(1000))
        XCTAssertEqual(table["d"]?.value, .integer(0xDEADBEEF))
        XCTAssertEqual(table["e"]?.value, .integer(0o755))
        XCTAssertEqual(table["f"]?.value, .integer(0b1101))
        XCTAssertEqual(table["g"]?.value, .float(3.1415))
        XCTAssertEqual(table["h"]?.value, .float(-0.01))
        XCTAssertEqual(table["i"]?.value, .float(5e22))
        XCTAssertEqual(table["j"]?.value, .float(6.626e-34))
        XCTAssertEqual(table["k"]?.value, .float(.infinity))
        XCTAssertEqual(table["l"]?.value, .float(-.infinity))
        XCTAssertEqual(table["m"]?.value, .integer(0))
        XCTAssertEqual(table["n"]?.value, .float(1000))
        guard case let .float(nan)? = try TOML.parse("x = nan")["x"]?.value else { return XCTFail() }
        XCTAssertTrue(nan.isNaN)
    }

    func testArraysAndArraysOfTables() throws {
        let table = try TOML.parse("""
            list = [
              1, # one
              "two",
              [3],
              { four = 4 },
            ]
            [[item]]
            name = "a"
            [[item]]
            name = "b"
            """)
        guard case let .array(list)? = table["list"]?.value, list.count == 4,
              case let .table(inline) = list[3]
        else { return XCTFail("\(table)") }
        XCTAssertEqual(Array(list[0..<3]), [.integer(1), .string("two"), .array([.integer(3)])])
        XCTAssertEqual(inline["four"], TOMLItem(value: .integer(4), line: 5))
        guard case let .array(items)? = table["item"]?.value else { return XCTFail() }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(table["item"]?.line, 7)
    }

    func testDateTimesAreKeptAsText() throws {
        let table = try TOML.parse("""
            a = 1979-05-27T07:32:00Z
            b = 1979-05-27 07:32:00-08:00
            c = 1979-05-27
            d = 07:32:00.999
            """)
        XCTAssertEqual(table["a"]?.value, .dateTime("1979-05-27T07:32:00Z"))
        XCTAssertEqual(table["b"]?.value, .dateTime("1979-05-27 07:32:00-08:00"))
        XCTAssertEqual(table["c"]?.value, .dateTime("1979-05-27"))
        XCTAssertEqual(table["d"]?.value, .dateTime("07:32:00.999"))
    }

    func testWindowsLineEndings() throws {
        let table = try TOML.parse("a = 1\r\n[t]\r\nb = \"x\"\r\n")
        guard case let .table(t)? = table["t"]?.value else { return XCTFail() }
        XCTAssertEqual(t["b"], TOMLItem(value: .string("x"), line: 3))
    }

    func testErrorsNameTheLine() {
        assertError("a = 1\nb = ", line: 2)
        assertError("a = 1\na = 2", line: 2, contains: "defined twice")
        assertError("[t]\nx = 1\n[t]", line: 3, contains: "already defined")
        assertError("a = \"unterminated\nb = 1", line: 1, contains: "unterminated")
        assertError("a = 1 b = 2", line: 1, contains: "end of the line")
        assertError("\n\na == 1", line: 3)
        assertError("a = 01", line: 1, contains: "invalid value")
        assertError("a = 1__0", line: 1)
        assertError("a = .5", line: 1)
        assertError("a = 1.", line: 1)
        assertError("a = \"\\q\"", line: 1, contains: "invalid escape")
        assertError("a = { b = 1 }\na.c = 2", line: 2)
        assertError("a = { b = 1, }", line: 1)
        assertError("a = [1 2]", line: 1)
        assertError("a.b = 1\n[a.b]", line: 2)
        assertError("a = 1\n[a.b]", line: 2)
        assertError("[a]\n[[a]]", line: 2)
        assertError("x = trueish", line: 1)
        assertError("= 1", line: 1, contains: "expected a key")
        assertError("a = \"\u{01}\"", line: 1, contains: "control characters")
    }

    private func assertError(_ text: String, line: Int, contains: String? = nil, file: StaticString = #filePath,
                             testLine: UInt = #line) {
        XCTAssertThrowsError(try TOML.parse(text), file: file, line: testLine) { error in
            guard let error = error as? TOMLError else { return XCTFail("\(error)", file: file, line: testLine) }
            XCTAssertEqual(error.line, line, "\(text.debugDescription): \(error)", file: file, line: testLine)
            if let contains {
                XCTAssertTrue(error.message.contains(contains), "\(error)", file: file, line: testLine)
            }
        }
    }
}
