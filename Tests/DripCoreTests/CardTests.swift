import DripCore
import Testing

extension Card {
    /// A card of `preset` that stays, as `--stay` makes it, such as an agent's that needs you.
    static func staying(_ preset: Preset = .info, title: String) -> Card {
        var card = Card(preset: preset, title: title)
        card.waitLimit = Defaults.waitLimit
        return card
    }
}

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
        #expect(Preset.builtIn.map(\.glyph) == ["checkmark", "exclamationmark", "xmark", "info"])
    }

    @Test func aCardThatStaysWaitsForYou() {
        let staying = Card.staying(title: "my-app needs you")
        #expect(staying.waits)
        #expect(staying.duration == Defaults.waitLimit)
        #expect(staying.seconds == Defaults.seconds)
        // A click takes it away, even with nothing to bring forward.
        #expect(staying.activate == nil && staying.action == nil && staying.isClickable)

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

        // A card that stays shows its own icon, which says the state already.
        var staying = Card.staying(title: "my-app needs you")
        #expect(staying.ringGlyph == nil)
        staying.icon = .app("com.anthropic.claudefordesktop")
        #expect(staying.ringGlyph == "info")
    }

    @Test func everyCardKeepsItsIcon() {
        var staying = Card.staying(title: "my-app needs you")
        #expect(staying.showsIconAtNotch)
        // A question keeps its icon, with one button or two, waiting or not.
        staying.action = CardAction(label: "Approve", open: nil)
        #expect(staying.showsIconAtNotch)
        staying.action?.decline = "Deny"
        #expect(staying.showsIconAtNotch)
        for preset in Preset.builtIn {
            var question = Card(preset: preset, title: "Deploy to prod?")
            question.action = CardAction(label: "Deploy", open: nil, decline: "Cancel")
            question.waitLimit = Defaults.waitLimit
            #expect(question.showsIconAtNotch)
        }
        staying.action = nil
        staying.icon = .mark("claude")
        #expect(staying.showsIconAtNotch)
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
        var staying = Card.staying(title: "my-app needs you")
        #expect(staying.showsWaitingMark)
        staying.icon = .mark("claude")
        #expect(staying.showsWaitingMark)
        // Its buttons stand there instead.
        staying.action = CardAction(label: "Approve", open: nil, decline: "Deny")
        #expect(!staying.showsWaitingMark)
        // Counting down, it shows its ring.
        staying = Card(preset: .info, title: "my-app needs you")
        #expect(!staying.showsWaitingMark)
        #expect(!Card(preset: .ok, title: "done").showsWaitingMark)
    }

    @Test func aFailureAQuestionOrACardThatStaysIsReadOutFirst() {
        #expect(Preset.builtIn.filter { Card(preset: $0, title: "t").isUrgent }.map(\.name) == ["fail"])
        // Any look that stays waits on you.
        #expect(Preset.builtIn.allSatisfy { Card.staying($0, title: "t").isUrgent })
        // So does a question of any look, counting down or not.
        for preset in Preset.builtIn {
            var question = Card(preset: preset, title: "Deploy to prod?")
            question.action = CardAction(label: "Deploy", open: nil)
            #expect(question.isUrgent)
        }
        // A link button asks nothing.
        var link = Card(preset: .ok, title: "Release 1.4 is out")
        link.action = CardAction(label: "View", open: "https://example.com")
        #expect(!link.isUrgent)
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
        #expect(card.size == .regular)
    }
}
