import BlipCore
import Testing

struct CardTests {
    @Test func builtInPresetsMatchTheSpec() {
        #expect(Preset.builtIn.map(\.name) == ["ok", "warn", "fail", "info"])
        #expect(Preset.ok.icon == .symbol("checkmark.circle.fill"))
        #expect(Preset.ok.color == .system(.green))
        #expect(Preset.ok.sound == .named("Glass"))
        #expect(Preset.warn.icon == .symbol("exclamationmark.circle.fill"))
        #expect(Preset.warn.color == .system(.orange))
        #expect(Preset.warn.sound == .named("Purr"))
        #expect(Preset.fail.icon == .symbol("xmark.circle.fill"))
        #expect(Preset.fail.color == .system(.red))
        #expect(Preset.fail.sound == .named("Basso"))
        #expect(Preset.info.icon == .symbol("info.circle.fill"))
        #expect(Preset.info.color == .system(.blue))
        #expect(Preset.info.sound == .named("Tink"))
        #expect(Preset.builtIn.allSatisfy { $0.seconds == nil })
    }

    @Test func colorParsesHexAndNames() {
        #expect(CardColor(parsing: "#a78bfa") == .rgb(red: 0xA7, green: 0x8B, blue: 0xFA))
        #expect(CardColor(parsing: "#A78BFA") == .rgb(red: 0xA7, green: 0x8B, blue: 0xFA))
        #expect(CardColor(parsing: "#000000") == .rgb(red: 0, green: 0, blue: 0))
        for name in SystemColor.allCases {
            #expect(CardColor(parsing: name.rawValue) == .system(name))
        }
        #expect(CardColor(parsing: "Green") == .system(.green))
    }

    @Test func colorRejectsMalformedValues() {
        for bad in ["", "#", "#fff", "a78bfa", "#a78bfg", "#a78bfa0", "teal", "#+78bfa", "# 78bfa"] {
            #expect(CardColor(parsing: bad) == nil, "\(bad)")
        }
    }

    @Test func iconParsing() {
        #expect(Icon(parsing: "none") == Icon.none)
        #expect(Icon(parsing: "paperplane.fill") == .symbol("paperplane.fill"))
    }

    @Test func soundParsing() {
        #expect(Sound(parsing: "none") == Sound.none)
        #expect(Sound(parsing: "Glass") == .named("Glass"))
        #expect(Sound(parsing: "/tmp/ding.aiff") == .file("/tmp/ding.aiff"))
        #expect(Sound(parsing: "ding.wav") == .file("ding.wav"))
        #expect(Sound(parsing: "Ding.AIF") == .file("Ding.AIF"))
        #expect(Sound(parsing: "./ding") == .file("./ding"))
    }

    @Test func sizeScales() {
        #expect(CardSize.compact.scale == 0.85)
        #expect(CardSize.regular.scale == 1.0)
        #expect(CardSize.large.scale == 1.25)
    }

    @Test func cardFromPresetUsesDefaults() {
        let card = Card(preset: .fail, title: "deploy failed", detail: "exit 1")
        #expect(card.kind == "fail")
        #expect(card.icon == .symbol("xmark.circle.fill"))
        #expect(card.fallbackIcon == card.icon)
        #expect(card.seconds == 4.5)
        #expect(card.position == .notch)
        #expect(card.size == .regular)
    }
}
