import DripCore
import Testing

/// What an agent's card that counts down does while its terminal is in front.
struct FocusTests {
    let done = Card(preset: .ok, title: "api is done")
    var waiting: Card {
        var card = Card(preset: .info, title: "api needs you")
        card.waitLimit = Defaults.waitLimit
        return card
    }

    @Test func quietWhenTheTerminalIsInFront() throws {
        let quiet = try #require(WhenFocused.quiet.apply(to: done, front: .init(app: true)))
        #expect(quiet.sound == .none)
        #expect(quiet.seconds == WhenFocused.quietSeconds)
        #expect(WhenFocused.quiet.apply(to: done, front: .init(app: false)) == done)
    }

    @Test func skippedOnlyOnThePanesWord() {
        #expect(WhenFocused.skip.apply(to: done, front: .init(app: true, pane: true)) == nil)
        // The app alone may hold another session's tab: quiet, never gone.
        #expect(WhenFocused.skip.apply(to: done, front: .init(app: true))?.sound == Sound.none)
        // Another pane shows: as any card.
        #expect(WhenFocused.skip.apply(to: done, front: .init(app: true, pane: false)) == done)
        #expect(WhenFocused.quiet.apply(to: done, front: .init(app: true, pane: false)) == done)
        // The pane shows in a terminal behind another app.
        #expect(WhenFocused.skip.apply(to: done, front: .init(app: false, pane: true)) == done)
    }

    @Test func aCardThatWaitsAlwaysShows() {
        for choice in WhenFocused.allCases {
            #expect(choice.apply(to: waiting, front: .init(app: true, pane: true)) == waiting)
        }
        #expect(WhenFocused.show.apply(to: done, front: .init(app: true, pane: true)) == done)
    }

    @Test func theSettingComesFromTheEnvironmentThenTheConfig() throws {
        #expect(CardResolver().whenFocused == .quiet)
        let config = try ConfigLoader.parse("when_focused = \"skip\"", path: "config.toml").config
        #expect(CardResolver(config: config).whenFocused == .skip)
        let environment = try EnvironmentSettings(environment: ["DRIP_WHEN_FOCUSED": "show"])
        #expect(CardResolver(config: config, environment: environment).whenFocused == .show)
        #expect(throws: UsageError.self) { try EnvironmentSettings(environment: ["DRIP_WHEN_FOCUSED": "loud"]) }
        #expect(throws: ConfigError.self) { try ConfigLoader.parse("when_focused = \"loud\"", path: "config.toml") }
    }
}
