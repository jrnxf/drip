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

    func testAParentTableMayBeDefinedAfterItsChild() throws {
        let table = try TOML.parse("[ preset . ok ]\nsound = \"Hero\"\n[preset]\nx = 1")
        guard case let .table(presets)? = table["preset"]?.value else { return XCTFail("\(table)") }
        XCTAssertEqual(presets.keys, ["ok", "x"])
        XCTAssertEqual(presets["x"], TOMLItem(value: .integer(1), line: 4))
    }

    func testStrings() throws {
        let table = try TOML.parse(#"""
            basic = "tab\there \"q\" \u00e9 \U0001F389 back\\slash # not a comment"
            literal = 'C:\path\no escapes'
            empty = ""
            emptyLiteral = ''
            """#)
        XCTAssertEqual(table["basic"]?.value, .string("tab\there \"q\" é 🎉 back\\slash # not a comment"))
        XCTAssertEqual(table["literal"]?.value, .string(#"C:\path\no escapes"#))
        XCTAssertEqual(table["empty"]?.value, .string(""))
        XCTAssertEqual(table["emptyLiteral"]?.value, .string(""))
    }

    func testNumbers() throws {
        let table = try TOML.parse("""
            a = +42
            b = -17
            c = 1_000
            g = 3.1415
            h = -0.01
            i = 5e+22
            j = 6.626e-34
            m = 0
            n = 1E3
            """)
        XCTAssertEqual(table["a"]?.value, .integer(42))
        XCTAssertEqual(table["b"]?.value, .integer(-17))
        XCTAssertEqual(table["c"]?.value, .integer(1000))
        XCTAssertEqual(table["g"]?.value, .float(3.1415))
        XCTAssertEqual(table["h"]?.value, .float(-0.01))
        XCTAssertEqual(table["i"]?.value, .float(5e22))
        XCTAssertEqual(table["j"]?.value, .float(6.626e-34))
        XCTAssertEqual(table["m"]?.value, .integer(0))
        XCTAssertEqual(table["n"]?.value, .float(1000))
    }

    func testWindowsLineEndings() throws {
        let table = try TOML.parse("a = 1\r\n[t]\r\nb = \"x\"\r\n")
        guard case let .table(t)? = table["t"]?.value else { return XCTFail() }
        XCTAssertEqual(t["b"], TOMLItem(value: .string("x"), line: 3))
    }

    func testErrorsNameTheLine() {
        assertError("a = 1\nb = ", line: 2, contains: "expected a value")
        assertError("a = 1\na = 2", line: 2, contains: "defined twice")
        assertError("[t]\nx = 1\n[t]", line: 3, contains: "already defined")
        assertError("a = \"unterminated\nb = 1", line: 1, contains: "unterminated")
        assertError("a = 'unterminated", line: 1, contains: "unterminated")
        assertError("a = 1 b = 2", line: 1, contains: "end of the line")
        assertError("\n\na == 1", line: 3)
        assertError("a = 01", line: 1, contains: "invalid value")
        assertError("a = 1__0", line: 1)
        assertError("a = .5", line: 1)
        assertError("a = 1.", line: 1)
        assertError("a = inf", line: 1, contains: "invalid value")
        assertError("a = \"\\q\"", line: 1, contains: "invalid escape")
        assertError("a = 1\n[a.b]", line: 2, contains: "already a value")
        assertError("[t\nx = 1", line: 1, contains: "expected ']'")
        assertError("x = trueish", line: 1, contains: "invalid value")
        assertError("= 1", line: 1, contains: "expected a key")
        assertError("a = \"\u{01}\"", line: 1, contains: "control characters")
    }

    func testUnsupportedSyntaxNamesTheLine() {
        assertError("a = 1\n[[item]]", line: 2, contains: "arrays of tables are not supported")
        assertError("a = 1\nlist = [1, 2]", line: 2, contains: "arrays are not supported")
        assertError("a = 1\nt = { b = 1 }", line: 2, contains: "inline tables are not supported")
        assertError("a = 1\npreset.ok.sound = \"Hero\"", line: 2, contains: "dotted keys are not supported")
        assertError("a = 1\n\"quoted\" = 1", line: 2, contains: "quoted keys are not supported")
        assertError("a = 1\n'quoted' = 1", line: 2, contains: "quoted keys are not supported")
        assertError("a = 1\n[preset.\"ok\"]", line: 2, contains: "quoted keys are not supported")
        assertError("a = 1\nb = \"\"\"\nx\"\"\"", line: 2, contains: "multi-line strings are not supported")
        assertError("a = 1\nb = '''x'''", line: 2, contains: "multi-line strings are not supported")
        assertError("a = 1\nb = 1979-05-27", line: 2, contains: "date-times are not supported")
        assertError("a = 1\nb = 1979-05-27T07:32:00Z", line: 2, contains: "date-times are not supported")
        assertError("a = 1\nb = 1979-05-27 07:32:00", line: 2, contains: "date-times are not supported")
        assertError("a = 1\nb = 07:32:00", line: 2, contains: "date-times are not supported")
        assertError("a = 1\nb = 0xff", line: 2, contains: "hexadecimal, octal and binary integers are not supported")
        assertError("a = 1\nb = 0o755", line: 2, contains: "hexadecimal, octal and binary integers are not supported")
        assertError("a = 1\nb = 0b1101", line: 2, contains: "hexadecimal, octal and binary integers are not supported")
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
