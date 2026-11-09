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
        let config = try ConfigLoader.parse("away_after = 300", path: "config.toml").config
        #expect(CardResolver(config: config).awayAfter == 300)
        let environment = try EnvironmentSettings(environment: ["DRIP_AWAY_AFTER": "90"])
        #expect(CardResolver(config: config, environment: environment).awayAfter == 90)
        #expect(throws: UsageError.self) { try EnvironmentSettings(environment: ["DRIP_AWAY_AFTER": "soon"]) }
        #expect(throws: ConfigError.self) { try ConfigLoader.parse("away_after = -1", path: "config.toml") }
    }

    /// The settings that moved into the recipes' flags are not keys any more.
    @Test func theKeysTheRecipesReplacedAreUnknown() throws {
        for line in ["agent_cards = \"attention\"", "done_after = 30", "approve = true"] {
            let file = try ConfigLoader.parse(line, path: "config.toml")
            #expect(file.config == Config(), "\(line)")
            #expect(file.warnings.count == 1 && file.warnings[0].contains("unknown key"), "\(line)")
        }
        // The variables are not read, so one left in a shell does nothing.
        let ignored = try EnvironmentSettings(environment: [
            "DRIP_AGENT_CARDS": "some", "DRIP_DONE_AFTER": "601", "DRIP_APPROVE": "maybe",
        ])
        #expect(ignored == EnvironmentSettings())
    }

    @Test(arguments: [
        (WhenFocused.Front(app: true, pane: true, idle: 5), Watching.Answer.watching),
        (.init(app: true, pane: nil, idle: 5), .watching),
        (.init(app: true, pane: false, idle: 5), .notWatching),
        (.init(app: false, pane: true, idle: 5), .notWatching),
        (.init(app: true, pane: true, idle: 120), .notWatching),
    ])
    func watchingIsTheFrontAndYouAtTheScreen(_ case: (front: WhenFocused.Front, answer: Watching.Answer)) {
        var card = Card(preset: .info, title: "x")
        card.activate = "com.example.terminal"
        #expect(Watching.answer(for: card, awayAfter: 60, front: { _ in `case`.front }, paneShowing: { _ in nil })
            == `case`.answer)
    }

    @Test func watchingAsksTmuxOnlyWhenTheAppIsInFrontAndYouAreHere() {
        var card = Card(preset: .info, title: "x")
        card.activate = "com.example.terminal"
        var asked = 0
        func answer(_ front: WhenFocused.Front, shows: Bool?) -> Watching.Answer {
            Watching.answer(for: card, awayAfter: 60, front: { _ in front }, paneShowing: { _ in asked += 1; return shows })
        }
        #expect(answer(.init(app: true, idle: 1), shows: false) == .notWatching)
        #expect(asked == 1)
        #expect(answer(.init(app: true, idle: 1), shows: true) == .watching)
        #expect(answer(.init(app: false, idle: 1), shows: true) == .notWatching)
        #expect(answer(.init(app: true, idle: 600), shows: true) == .notWatching)
        #expect(asked == 2)
    }

    @Test func watchingCannotTellWithoutATerminalApp() {
        let card = Card(preset: .info, title: "x")
        #expect(Watching.answer(for: card, awayAfter: 60, front: { _ in .init(app: true) }, paneShowing: { _ in true }) == .unknown)
        #expect(Watching.Answer.watching.status == 0)
        #expect(Watching.Answer.notWatching.status == 1)
        #expect(Watching.Answer.unknown.status == 2)
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
