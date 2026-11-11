import DripCore
import Testing

struct TOMLTests {
    @Test func scalarsAndLines() throws {
        let table = try TOML.parse("""
            # a comment
            seconds  = 4.5
            position = "bottom"          # trailing comment
            count = 3
            sound    = false
            """)
        #expect(table.keys == ["seconds", "position", "count", "sound"])
        #expect(table["seconds"] == TOMLItem(value: .float(4.5), line: 2))
        #expect(table["position"] == TOMLItem(value: .string("bottom"), line: 3))
        #expect(table["count"] == TOMLItem(value: .integer(3), line: 4))
        #expect(table["sound"] == TOMLItem(value: .boolean(false), line: 5))
    }

    @Test func tables() throws {
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
        else { Issue.record("\(table)"); return }
        #expect(presets.keys == ["ok", "deploy"])
        #expect(presets["ok"]?.line == 1)
        #expect(presets["deploy"]?.line == 4)
        #expect(ok["sound"] == TOMLItem(value: .string("Hero"), line: 2))
        #expect(deploy["seconds"] == TOMLItem(value: .integer(6), line: 6))
    }

    @Test func aParentTableMayBeDefinedAfterItsChild() throws {
        let table = try TOML.parse("[ preset . ok ]\nsound = \"Hero\"\n[preset]\nx = 1")
        guard case let .table(presets)? = table["preset"]?.value else { Issue.record("\(table)"); return }
        #expect(presets.keys == ["ok", "x"])
        #expect(presets["x"] == TOMLItem(value: .integer(1), line: 4))
    }

    @Test func strings() throws {
        let table = try TOML.parse(#"""
            basic = "tab\there \"q\" \u00e9 \U0001F389 back\\slash # not a comment"
            literal = 'C:\path\no escapes'
            empty = ""
            emptyLiteral = ''
            """#)
        #expect(table["basic"]?.value == .string("tab\there \"q\" é 🎉 back\\slash # not a comment"))
        #expect(table["literal"]?.value == .string(#"C:\path\no escapes"#))
        #expect(table["empty"]?.value == .string(""))
        #expect(table["emptyLiteral"]?.value == .string(""))
    }

    @Test func numbers() throws {
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
        #expect(table["a"]?.value == .integer(42))
        #expect(table["b"]?.value == .integer(-17))
        #expect(table["c"]?.value == .integer(1000))
        #expect(table["g"]?.value == .float(3.1415))
        #expect(table["h"]?.value == .float(-0.01))
        #expect(table["i"]?.value == .float(5e22))
        #expect(table["j"]?.value == .float(6.626e-34))
        #expect(table["m"]?.value == .integer(0))
        #expect(table["n"]?.value == .float(1000))
    }

    @Test func windowsLineEndings() throws {
        let table = try TOML.parse("a = 1\r\n[t]\r\nb = \"x\"\r\n")
        guard case let .table(t)? = table["t"]?.value else { Issue.record(); return }
        #expect(t["b"] == TOMLItem(value: .string("x"), line: 3))
    }

    @Test func errorsNameTheLine() {
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
        assertError("position = top", line: 1, contains: "invalid value 'top'; a string needs quotes: \"top\"")
        assertError("color = #a78bfa", line: 1, contains: "a color needs quotes, as in \"#a78bfa\"")
        assertError("= 1", line: 1, contains: "expected a key")
        assertError("a = \"\u{01}\"", line: 1, contains: "control characters")
    }

    @Test func unsupportedSyntaxNamesTheLine() {
        assertError("a = 1\n[[item]]", line: 2, contains: "arrays of tables are not supported")
        assertError("a = 1\nlist = [1, 2]", line: 2, contains: "arrays are not supported")
        assertError("a = 1\n\"quoted\" = 1", line: 2, contains: "quoted keys are not supported")
        assertError("a = 1\n'quoted' = 1", line: 2, contains: "quoted keys are not supported")
        assertError("a = 1\n[preset.\"ok\"]", line: 2, contains: "quoted keys are not supported")
        assertError("a = 1\n[preset.ok.sound]", line: 2, contains: "at most 2 keys")
        // A header thousands of keys deep is an error, not a crash.
        let deep = "[" + Array(repeating: "a", count: 50_000).joined(separator: ".") + "]"
        assertError(deep, line: 1, contains: "at most 2 keys")
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

    @Test func dottedKeysMakeTables() throws {
        let table = try TOML.parse("""
            preset.ok.sound = "Hero"
            preset . ok . seconds = 3
            [t]
            a.b = 1
            a.c = 2
            """)
        guard case let .table(presets)? = table["preset"]?.value,
              case let .table(ok)? = presets["ok"]?.value,
              case let .table(t)? = table["t"]?.value,
              case let .table(a)? = t["a"]?.value
        else { Issue.record("\(table)"); return }
        #expect(ok.keys == ["sound", "seconds"])
        #expect(ok["sound"] == TOMLItem(value: .string("Hero"), line: 1))
        #expect(ok["seconds"] == TOMLItem(value: .integer(3), line: 2))
        #expect(a.keys == ["b", "c"])
        #expect(a["c"] == TOMLItem(value: .integer(2), line: 5))
    }

    @Test func inlineTablesMakeTables() throws {
        let table = try TOML.parse("""
            t = { a = 1, b.c = "x", d = { e = true }, f = {} }
            [preset]
            ci = { sound = "Hero" }
            """)
        guard case let .table(t)? = table["t"]?.value,
              case let .table(b)? = t["b"]?.value,
              case let .table(d)? = t["d"]?.value,
              case let .table(f)? = t["f"]?.value,
              case let .table(presets)? = table["preset"]?.value,
              case let .table(ci)? = presets["ci"]?.value
        else { Issue.record("\(table)"); return }
        #expect(t.keys == ["a", "b", "d", "f"])
        #expect(t["a"] == TOMLItem(value: .integer(1), line: 1))
        #expect(b["c"] == TOMLItem(value: .string("x"), line: 1))
        #expect(d["e"] == TOMLItem(value: .boolean(true), line: 1))
        #expect(f.keys.isEmpty)
        #expect(ci["sound"] == TOMLItem(value: .string("Hero"), line: 3))
        #expect(presets["ci"]?.line == 3)
    }

    @Test func dottedKeysAndHeadersMix() throws {
        // TOML 1.0: a header may add a new sub-table below a dotted key's table.
        let table = try TOML.parse("[fruit]\napple.color = \"red\"\n[fruit.apple.texture]\nsmooth = true")
        guard case let .table(fruit)? = table["fruit"]?.value,
              case let .table(apple)? = fruit["apple"]?.value
        else { Issue.record("\(table)"); return }
        #expect(apple.keys == ["color", "texture"])
        // A parent table may be defined after its child, and dotted keys may follow a header.
        _ = try TOML.parse("[a.b]\nx = 1\n[a]\nc.d = 1")
    }

    @Test func tablesCannotBeRedefined() {
        assertError("a.b = 1\na.b = 2", line: 2, contains: "'a.b' is defined twice")
        assertError("a.b = 1\na = 2", line: 2, contains: "defined twice")
        assertError("a = 1\na.b = 2", line: 2, contains: "'a' is already a value")
        assertError("a.b = 1\n[a]", line: 2, contains: "already defined")
        assertError("[a]\nb.c = 1\n[a.b]", line: 3, contains: "already defined")
        assertError("[a.b]\n[a]\nb.c = 1", line: 3, contains: "already defined as a table")
        assertError("[a]\nb = { c = 1 }\nb.d = 2", line: 3, contains: "already defined as a table")
        assertError("a = { b = 1 }\n[a]", line: 2, contains: "an inline table")
        assertError("a = { b = 1 }\n[a.c]", line: 2, contains: "'a' is an inline table, so [a.c] cannot add to it")
        assertError("[a]\nb = {}\n[a.b]", line: 3, contains: "already defined")
        assertError("[a]\nb = { c = 1 }\n[a.b]", line: 3, contains: "already defined")
        assertError("a = { b = 1, b = 2 }", line: 1, contains: "defined twice")
        assertError("a = { b.c = 1, b = 2 }", line: 1, contains: "defined twice")
        assertError("a = { b = { c = 1 }, b.d = 2 }", line: 1, contains: "already defined as a table")
    }

    @Test func theLimitAllowsEightTables() throws {
        _ = try TOML.parse("a.b.c.d.e.f.g.h.i = 1")
        _ = try TOML.parse("a = { b.c = { d.e = { f.g = 1 } } }")
        _ = try TOML.parse("a.b.c.d.e.f.g = {}")
    }

    @Test func malformedInlineTablesAndDottedKeys() {
        assertError("a = 1\nt = { b = 1", line: 2, contains: "unterminated inline table")
        assertError("t = { b = 1,", line: 1, contains: "unterminated inline table")
        assertError("t = { b = 1, }", line: 1, contains: "trailing comma")
        assertError("t = { b = 1 c = 2 }", line: 1, contains: "expected ',' or '}'")
        assertError("t = { , }", line: 1, contains: "expected a key")
        assertError("t = { b }", line: 1, contains: "expected '='")
        assertError("t = { b = }", line: 1, contains: "expected a value")
        assertError("t = { b = 1 } x", line: 1, contains: "end of the line")
        assertError("a. = 1", line: 1, contains: "expected a key")
        assertError(".a = 1", line: 1, contains: "expected a key")
        assertError("a..b = 1", line: 1, contains: "expected a key")
        assertError("a.\"b\" = 1", line: 1, contains: "quoted keys are not supported")
        // Deep nesting is an error, not a crash.
        assertError(Array(repeating: "a", count: 50_000).joined(separator: ".") + " = 1", line: 1, contains: "at most 8 tables")
        assertError("t = " + String(repeating: "{ a = ", count: 50_000), line: 1, contains: "at most 8 tables")
        // One limit counts dotted keys and inline tables together.
        assertError("a.b.c.d.e.f.g.h.i.j = 1", line: 1, contains: "at most 8 tables")
        assertError("a.b.c.d.e.f.g = { h = { i = {} } }", line: 1, contains: "at most 8 tables")
        assertError("a = { b.c = { d.e = { f.g = { h.i = {} } } } }", line: 1, contains: "at most 8 tables")
    }

    private func assertError(
        _ text: String, line: Int, contains: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let error = #expect(throws: TOMLError.self, sourceLocation: sourceLocation) { try TOML.parse(text) }
        guard let error else { return }
        #expect(error.line == line, "\(text.debugDescription): \(error)", sourceLocation: sourceLocation)
        if let contains {
            #expect(error.message.contains(contains), "\(error)", sourceLocation: sourceLocation)
        }
    }
}
