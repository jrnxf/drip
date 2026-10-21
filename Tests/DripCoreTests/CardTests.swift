import DripCore
import Testing

struct CardTests {
    @Test func builtInPresetsMatchTheSpec() {
        #expect(Preset.builtIn.map(\.name) == ["ok", "warn", "fail", "info", "ask"])
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
        #expect(Preset.ask.icon == .symbol("questionmark.circle.fill"))
        #expect(Preset.ask.color == .system(.purple))
        #expect(Preset.ask.sound == .named("Ping"))
        #expect(Preset.builtIn.allSatisfy { $0.seconds == nil })
        #expect(Preset.builtIn.filter(\.waits).map(\.name) == ["ask"])
        #expect(Preset.builtIn.map(\.glyph) == ["checkmark", "exclamationmark", "xmark", "info", "questionmark"])
    }

    @Test func anAskCardWaitsForYou() {
        let ask = Card(preset: .ask, title: "my-app needs you")
        #expect(ask.waits)
        #expect(ask.waitLimit == Defaults.waitLimit)
        #expect(ask.duration == Defaults.waitLimit)
        #expect(ask.seconds == Defaults.seconds)
        // A click takes it away, even with nothing to bring forward.
        #expect(ask.activate == nil && ask.action == nil && ask.isClickable)

        let ok = Card(preset: .ok, title: "done")
        #expect(!ok.waits)
        #expect(ok.duration == Defaults.seconds)
        #expect(!ok.isClickable)
    }

    @Test func theRingCarriesTheStateWhenTheIconIsNotTheStates() {
        var card = Card(preset: .ok, title: "my-app is done")
        #expect(card.ringGlyph == nil)
        card.icon = .app("com.anthropic.claudefordesktop")
        #expect(card.ringGlyph == "checkmark")
        card.icon = .image("/home/user/agent.png")
        #expect(card.ringGlyph == "checkmark")
        card.icon = .symbol("terminal.fill")
        #expect(card.ringGlyph == "checkmark")
        card.icon = .mark("claude")
        #expect(card.ringGlyph == "checkmark")
        // No icon at all: the card reads as before.
        card.icon = .none
        #expect(card.ringGlyph == nil)

        // A card that waits has no countdown in its ring, so the ring always carries the state,
        // even beside the preset's own icon or none.
        var asking = Card(preset: .ask, title: "my-app needs you")
        #expect(asking.ringGlyph == "questionmark")
        asking.icon = .none
        #expect(asking.ringGlyph == "questionmark")
        // Given a time, it counts down like any other card, and reads as one.
        asking = Card(preset: .ask, title: "my-app needs you")
        asking.waitLimit = nil
        #expect(asking.ringGlyph == nil)
        asking.icon = .app("com.anthropic.claudefordesktop")
        #expect(asking.ringGlyph == "questionmark")
    }

    @Test func theNotchShowsTheStateOnce() {
        // A plain ask card's question is in its ring, so its own question icon is not shown too.
        var asking = Card(preset: .ask, title: "my-app needs you")
        #expect(!asking.showsIconAtNotch)
        // Its one button takes the ring's place, so its icon shows the question.
        asking.action = CardAction(label: "Approve", open: nil)
        #expect(asking.ringGlyph == "questionmark")
        #expect(asking.showsIconAtNotch)
        // Its yes and no buttons say what it asks: no icon.
        asking.action?.decline = "Deny"
        #expect(!asking.showsIconAtNotch)
        // A question that does not wait keeps its state's icon.
        var promote = Card(preset: .warn, title: "staging is ready")
        promote.action = CardAction(label: "Promote", open: nil)
        #expect(promote.showsIconAtNotch)
        asking.action = nil
        asking.icon = .mark("claude")
        #expect(asking.showsIconAtNotch)
        asking.icon = .symbol("bell.fill")
        #expect(asking.showsIconAtNotch)
        // Counting down, its ring shows the time, and the icon the state.
        asking = Card(preset: .ask, title: "my-app needs you")
        asking.waitLimit = nil
        #expect(asking.showsIconAtNotch)
        #expect(Card(preset: .ok, title: "done").showsIconAtNotch)
        var plain = Card(preset: .ok, title: "done")
        plain.icon = .none
        #expect(!plain.showsIconAtNotch)

        // A custom preset has no state of its own to show.
        var custom = Card(preset: Preset(name: "deploy", icon: .symbol("paperplane.fill"), color: .system(.purple), sound: .none), title: "t")
        custom.icon = .image("/home/user/logo.png")
        #expect(custom.ringGlyph == nil)
    }

    @Test func aCardThatWaitsShowsTheWaitingMark() {
        var asking = Card(preset: .ask, title: "my-app needs you")
        #expect(asking.showsWaitingMark)
        asking.icon = .mark("claude")
        #expect(asking.showsWaitingMark)
        // Its buttons stand there instead.
        asking.action = CardAction(label: "Approve", open: nil, decline: "Deny")
        #expect(!asking.showsWaitingMark)
        // Counting down, it shows its ring.
        asking = Card(preset: .ask, title: "my-app needs you")
        asking.waitLimit = nil
        #expect(!asking.showsWaitingMark)
        #expect(!Card(preset: .ok, title: "done").showsWaitingMark)
    }

    @Test func aFailureOrAnAskIsReadOutFirst() {
        #expect(Preset.builtIn.filter { Card(preset: $0, title: "t").isUrgent }.map(\.name) == ["fail", "ask"])
        // An ask card that counts down or has a button still waits on you.
        var asking = Card(preset: .ask, title: "my-app needs you")
        asking.waitLimit = nil
        asking.action = CardAction(label: "Approve", open: nil)
        #expect(asking.isUrgent)
        #expect(!Card(preset: Preset(name: "deploy", icon: .none, color: .system(.purple), sound: .none), title: "t").isUrgent)
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
        #expect(Icon(parsing: "app:com.openai.chat") == .app("com.openai.chat"))
        #expect(Icon(parsing: "/home/user/claude.png") == .image("/home/user/claude.png"))
        #expect(Icon(parsing: "~/claude.png") == .image("~/claude.png"))
        #expect(Icon(parsing: "logo.PNG") == .image("logo.PNG"))
        #expect(Icon(parsing: "mark.icns") == .image("mark.icns"))
        #expect(Icon(parsing: "./mark") == .image("./mark"))
        #expect(Icon(parsing: "app:com.openai.chat").problem == nil)
        #expect(Icon(parsing: "app:").problem != nil)
        #expect(Icon(parsing: "app:not a bundle id").problem != nil)
        #expect(Icon(parsing: "paperplane.fill").problem == nil)
    }

    @Test func anImagePathIsMadeAbsolute() {
        #expect(Icon.image("logos/claude.png").resolved(from: "/home/user/work") == .image("/home/user/work/logos/claude.png"))
        #expect(Icon.image("../claude.png").resolved(from: "/home/user/work") == .image("/home/user/claude.png"))
        #expect(Icon.image("/opt/claude.png").resolved(from: "/home/user") == .image("/opt/claude.png"))
        #expect(Icon.symbol("star").resolved(from: "/home/user") == .symbol("star"))
        #expect(Icon.app("com.openai.chat").resolved(from: "/home/user") == .app("com.openai.chat"))
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
