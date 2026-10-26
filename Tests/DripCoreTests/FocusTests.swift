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

    @Test func aCardThatWaitsIsNeverQuieted() {
        #expect(WhenFocused.quiet.apply(to: waiting, front: .init(app: true, pane: true)) == waiting)
        #expect(WhenFocused.quiet.apply(to: waiting, front: .init(app: true)) == waiting)
        #expect(WhenFocused.show.apply(to: waiting, front: .init(app: true, pane: true)) == waiting)
        #expect(WhenFocused.show.apply(to: done, front: .init(app: true, pane: true)) == done)
        // Skipped on the pane's word, as a done card is.
        #expect(WhenFocused.skip.apply(to: waiting, front: .init(app: true, pane: true)) == nil)
        #expect(WhenFocused.skip.apply(to: waiting, front: .init(app: true)) == waiting)
        #expect(WhenFocused.skip.apply(to: waiting, front: .init(app: true, pane: false)) == waiting)
    }

    @Test func aTerminalInFrontOfAnEmptyRoomIsNotWatched() {
        let away = WhenFocused.defaultAwayAfter
        let here = WhenFocused.defaultAwayAfter - 1
        for card in [done, waiting] {
            #expect(WhenFocused.skip.apply(to: card, front: .init(app: true, pane: true, idle: away)) == card)
            #expect(WhenFocused.skip.apply(to: card, front: .init(app: true, pane: true, idle: here)) == nil)
        }
        #expect(WhenFocused.quiet.apply(to: done, front: .init(app: true, idle: away)) == done)
        #expect(WhenFocused.quiet.apply(to: done, front: .init(app: true, idle: here))?.sound == Sound.none)
        // Your own away_after: five minutes keeps you at the screen, 0 never does.
        let front = WhenFocused.Front(app: true, pane: true, idle: 120)
        #expect(WhenFocused.skip.apply(to: done, front: front) == done)
        #expect(WhenFocused.skip.apply(to: done, front: front, awayAfter: 300) == nil)
        #expect(WhenFocused.skip.apply(to: done, front: .init(app: true, pane: true, idle: 0), awayAfter: 0) == done)
    }

    @Test func theAgentSettingsComeFromTheEnvironmentThenTheConfig() throws {
        #expect(CardResolver().awayAfter == 60)
        #expect(CardResolver().agentCards == .all)
        #expect(CardResolver().doneAfter == 0)
        let config = try ConfigLoader.parse(
            "away_after = 300\nagent_cards = \"attention\"\ndone_after = 30", path: "config.toml").config
        #expect(CardResolver(config: config).awayAfter == 300)
        #expect(CardResolver(config: config).agentCards == .attention)
        #expect(CardResolver(config: config).doneAfter == 30)
        let environment = try EnvironmentSettings(environment: [
            "DRIP_AWAY_AFTER": "90", "DRIP_AGENT_CARDS": "all", "DRIP_DONE_AFTER": "0",
        ])
        let resolver = CardResolver(config: config, environment: environment)
        #expect(resolver.awayAfter == 90)
        #expect(resolver.agentCards == .all)
        #expect(resolver.doneAfter == 0)
        #expect(throws: UsageError.self) { try EnvironmentSettings(environment: ["DRIP_DONE_AFTER": "601"]) }
        #expect(throws: UsageError.self) { try EnvironmentSettings(environment: ["DRIP_AWAY_AFTER": "soon"]) }
        #expect(throws: UsageError.self) { try EnvironmentSettings(environment: ["DRIP_AGENT_CARDS": "some"]) }
        #expect(throws: ConfigError.self) { try ConfigLoader.parse("away_after = -1", path: "config.toml") }
        #expect(throws: ConfigError.self) { try ConfigLoader.parse("agent_cards = \"some\"", path: "config.toml") }
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
