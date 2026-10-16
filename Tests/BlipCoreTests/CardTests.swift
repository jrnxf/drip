import BlipCore
import XCTest

final class CardTests: XCTestCase {
    func testBuiltInPresetsMatchTheSpec() {
        XCTAssertEqual(Preset.builtIn.map(\.name), ["ok", "warn", "fail", "info"])
        XCTAssertEqual(Preset.ok.icon, .symbol("checkmark.circle.fill"))
        XCTAssertEqual(Preset.ok.color, .system(.green))
        XCTAssertEqual(Preset.ok.sound, .named("Glass"))
        XCTAssertEqual(Preset.warn.icon, .symbol("exclamationmark.circle.fill"))
        XCTAssertEqual(Preset.warn.color, .system(.orange))
        XCTAssertEqual(Preset.warn.sound, .named("Purr"))
        XCTAssertEqual(Preset.fail.icon, .symbol("xmark.circle.fill"))
        XCTAssertEqual(Preset.fail.color, .system(.red))
        XCTAssertEqual(Preset.fail.sound, .named("Basso"))
        XCTAssertEqual(Preset.info.icon, .symbol("info.circle.fill"))
        XCTAssertEqual(Preset.info.color, .system(.blue))
        XCTAssertEqual(Preset.info.sound, .named("Tink"))
        XCTAssertTrue(Preset.builtIn.allSatisfy { $0.seconds == nil })
    }

    func testColorParsesHexAndNames() {
        XCTAssertEqual(CardColor(parsing: "#a78bfa"), .rgb(red: 0xA7, green: 0x8B, blue: 0xFA))
        XCTAssertEqual(CardColor(parsing: "#A78BFA"), .rgb(red: 0xA7, green: 0x8B, blue: 0xFA))
        XCTAssertEqual(CardColor(parsing: "#000000"), .rgb(red: 0, green: 0, blue: 0))
        for name in SystemColor.allCases {
            XCTAssertEqual(CardColor(parsing: name.rawValue), .system(name))
        }
        XCTAssertEqual(CardColor(parsing: "Green"), .system(.green))
    }

    func testColorRejectsMalformedValues() {
        for bad in ["", "#", "#fff", "a78bfa", "#a78bfg", "#a78bfa0", "teal", "#+78bfa", "# 78bfa"] {
            XCTAssertNil(CardColor(parsing: bad), bad)
        }
    }

    func testIconParsing() {
        XCTAssertEqual(Icon(parsing: "none"), Icon.none)
        XCTAssertEqual(Icon(parsing: "paperplane.fill"), .symbol("paperplane.fill"))
    }

    func testSoundParsing() {
        XCTAssertEqual(Sound(parsing: "none"), Sound.none)
        XCTAssertEqual(Sound(parsing: "Glass"), .named("Glass"))
        XCTAssertEqual(Sound(parsing: "/tmp/ding.aiff"), .file("/tmp/ding.aiff"))
        XCTAssertEqual(Sound(parsing: "ding.wav"), .file("ding.wav"))
        XCTAssertEqual(Sound(parsing: "Ding.AIF"), .file("Ding.AIF"))
        XCTAssertEqual(Sound(parsing: "./ding"), .file("./ding"))
    }

    func testSizeScales() {
        XCTAssertEqual(CardSize.compact.scale, 0.85)
        XCTAssertEqual(CardSize.regular.scale, 1.0)
        XCTAssertEqual(CardSize.large.scale, 1.25)
    }

    func testCardFromPresetUsesDefaults() {
        let card = Card(preset: .fail, title: "deploy failed", detail: "exit 1")
        XCTAssertEqual(card.kind, "fail")
        XCTAssertEqual(card.icon, .symbol("xmark.circle.fill"))
        XCTAssertEqual(card.fallbackIcon, card.icon)
        XCTAssertEqual(card.seconds, 4.5)
        XCTAssertEqual(card.position, .bottom)
        XCTAssertEqual(card.size, .regular)
    }
}
