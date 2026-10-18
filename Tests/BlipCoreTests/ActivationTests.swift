import BlipCore
import Testing

struct ActivationTests {
    @Test func theFlagBeatsTheSender() {
        #expect(CardActivation.target(flag: "com.googlecode.iterm2", sender: "com.apple.Terminal")
            == "com.googlecode.iterm2")
        #expect(CardActivation.target(flag: nil, sender: "com.apple.Terminal") == "com.apple.Terminal")
        #expect(CardActivation.target(flag: nil, sender: nil) == nil)
    }

    @Test func noneTurnsItOff() {
        #expect(CardActivation.target(flag: "none", sender: "com.apple.Terminal") == nil)
    }

    @Test func theSenderComesFromTheEnvironment() {
        #expect(CardActivation.sender(in: ["__CFBundleIdentifier": "com.mitchellh.ghostty"]) == "com.mitchellh.ghostty")
        #expect(CardActivation.sender(in: [:]) == nil)
        for bad in ["", "0x0", "com..x", "com.x.", "com x"] where bad != "0x0" {
            #expect(CardActivation.sender(in: ["__CFBundleIdentifier": bad]) == nil, "\(bad)")
        }
    }

    @Test func bundleIdentifiers() {
        for good in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "Terminal"] {
            #expect(CardActivation.isBundleIdentifier(good), "\(good)")
        }
        for bad in ["", ".", "com.", ".com", "com..apple", "com apple", "com/apple", "com.apple!", "côm.apple",
                    String(repeating: "a", count: 256)] {
            #expect(!CardActivation.isBundleIdentifier(bad), "\(bad)")
        }
    }

    @Test func theEnvironmentNotesTheSender() throws {
        #expect(try EnvironmentSettings(environment: ["__CFBundleIdentifier": "com.apple.Terminal"]).sender
            == "com.apple.Terminal")
        #expect(try EnvironmentSettings(environment: ["__CFBundleIdentifier": "not valid"]).sender == nil)
    }

    @Test func cardsActivateTheSenderUnlessTold() throws {
        let resolver = CardResolver(environment: EnvironmentSettings(sender: "com.apple.Terminal"))
        let card = try resolver.resolve(kind: "ok", title: "hi", flags: CardFlags())
        #expect(card.activate == "com.apple.Terminal")
        #expect(card.isClickable)
        #expect(try resolver.resolve(kind: "ok", title: "hi", flags: CardFlags(activate: "none")).activate == nil)
        #expect(try resolver.resolve(kind: "ok", title: "hi", flags: CardFlags(activate: "com.x.y")).activate == "com.x.y")
        let alone = try CardResolver().resolve(kind: "ok", title: "hi", flags: CardFlags())
        #expect(alone.activate == nil)
        #expect(!alone.isClickable)
    }

    @Test func runCardsActivateTheSenderToo() throws {
        let resolver = CardResolver(environment: EnvironmentSettings(sender: "com.apple.Terminal"))
        let card = try resolver.resolveRun(command: ["make"], status: 0, seconds: 1, flags: CardFlags(id: "build"))
        #expect(card.activate == "com.apple.Terminal")
        #expect(card.id == "build")
    }
}
