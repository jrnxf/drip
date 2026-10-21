import DripCore
import Testing

struct JSONTests {
    @Test func readsEveryKindOfValue() throws {
        let value = try JSONValue(parsing: """
            {"s": "a\\"b\\\\c\\/d\\n\\t\\u00e9\\ud83d\\ude00", "n": -1.50e+3, "z": 0, "t": true, "f": false,
             "null": null, "a": [1, [], {}], "o": {"k": "v"}}
            """)
        #expect(value["s"] == .string("a\"b\\c/d\n\té😀"))
        #expect(value["n"] == .number("-1.50e+3"))
        #expect(value["z"] == .number("0"))
        #expect(value["t"] == .bool(true))
        #expect(value["f"] == .bool(false))
        #expect(value["null"] == .null)
        #expect(value["a"] == .array([.number("1"), .array([]), .object([])]))
        #expect(value["o"]?["k"]?.string == "v")
        #expect(value["missing"] == nil)
    }

    @Test func keepsTheOrderOfKeys() throws {
        let value = try JSONValue(parsing: #"{"zebra": 1, "apple": 2, "mango": 3}"#)
        #expect(value.members?.map(\.key) == ["zebra", "apple", "mango"])
    }

    /// A key written twice reads as its last value, as JavaScript reads it.
    @Test func theLastOfARepeatedKeyWins() throws {
        #expect(try JSONValue(parsing: #"{"a": 1, "a": 2}"#)["a"] == .number("2"))
    }

    @Test func readsOnlyStrictJSON() {
        let invalid = [
            "", "   ", "{", "}", "[1,]", #"{"a": 1,}"#, "{'a': 1}", #"{"a" 1}"#, "01", "1.", ".5", "-", "1e",
            "+1", "tru", "nul", "NaN", #""unterminated"#, "\"a\nb\"", #""\x""#, #""\u12""#, "[1 2]", "{} {}",
            "// comment\n{}", "{\n  // comment\n}", "/* c */ {}",
        ]
        for text in invalid {
            #expect(throws: JSONError.self, "\(text)") { try JSONValue(parsing: text) }
        }
    }

    @Test func saysOnWhichLineItFailed() {
        #expect(throws: JSONError(line: 3, problem: "comments are not JSON")) {
            try JSONValue(parsing: "{\n  \"a\": 1,\n  // the theme\n  \"b\": 2\n}")
        }
        #expect(throws: JSONError(line: 2, problem: "expected , or } in an object")) {
            try JSONValue(parsing: "{\"a\": 1\n\"b\": 2}")
        }
    }

    @Test func aLoneSurrogateIsTheReplacementCharacter() throws {
        #expect(try JSONValue(parsing: #""\ud800x""#) == .string("\u{FFFD}x"))
        #expect(try JSONValue(parsing: #""\ud800A""#) == .string("\u{FFFD}A"))
    }

    /// Deep nesting is an error, not a stack overflow.
    @Test func deepNestingIsAnError() {
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        #expect(throws: JSONError.self) { try JSONValue(parsing: deep) }
        let fine = String(repeating: "[", count: 60) + String(repeating: "]", count: 60)
        #expect((try? JSONValue(parsing: fine)) != nil)
    }

    @Test func writesAsJavaScriptDoes() throws {
        let value = try JSONValue(parsing: """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"drip hook claude"}]}]},"empty":{},"list":[],
             "n":1.0,"s":"tab\\tquote\\"é\\u0001"}
            """)
        #expect(value.formatted() == """
            {
              "hooks": {
                "Stop": [
                  {
                    "hooks": [
                      {
                        "type": "command",
                        "command": "drip hook claude"
                      }
                    ]
                  }
                ]
              },
              "empty": {},
              "list": [],
              "n": 1.0,
              "s": "tab\\tquote\\"é\\u0001"
            }
            """)
        #expect(JSONValue.array([.null, .bool(true)]).formatted(indent: "\t") == "[\n\tnull,\n\ttrue\n]")
    }

    @Test func writtenTextReadsBackTheSame() throws {
        let text = #"{"a": [1, 2.5e-3, {"b": null}], "c": "  \\ \" \/ 😀", "d": {"e": [], "f": {}}}"#
        let value = try JSONValue(parsing: text)
        #expect(try JSONValue(parsing: value.formatted()) == value)
        #expect(try JSONValue(parsing: value.formatted(indent: "    ")) == value)
    }

    @Test func findsTheIndent() {
        #expect(JSONValue.indent(of: "{\n    \"a\": 1\n}") == "    ")
        #expect(JSONValue.indent(of: "{\n\t\"a\": 1\n}") == "\t")
        #expect(JSONValue.indent(of: "{\"a\": 1}") == "  ")
        #expect(JSONValue.indent(of: "") == "  ")
    }
}
