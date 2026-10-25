import DripCore
import Testing

/// The terminal pane a card came from, which a click on it selects.
struct TerminalPaneTests {
    @Test func tmuxNamesItsPane() throws {
        let pane = try #require(TerminalPane(environment: ["TMUX": "/private/tmp/tmux-501/default,4242,0", "TMUX_PANE": "%3"]))
        #expect(pane == TerminalPane(tmuxSocket: "/private/tmp/tmux-501/default", tmuxPane: "%3"))
        #expect(pane.selectCommands == [
            ["tmux", "-S", "/private/tmp/tmux-501/default", "select-window", "-t", "%3"],
            ["tmux", "-S", "/private/tmp/tmux-501/default", "select-pane", "-t", "%3"],
        ])
        // tmux inside WezTerm: tmux's pane is the one that matters.
        #expect(TerminalPane(environment: ["TMUX": "/tmp/t,1,0", "TMUX_PANE": "%1", "WEZTERM_PANE": "7"])?.tmuxPane == "%1")
    }

    @Test func wezTermNamesItsPane() {
        let pane = TerminalPane(environment: ["WEZTERM_PANE": "12"])
        #expect(pane == TerminalPane(weztermPane: "12"))
        #expect(pane?.selectCommands == [["wezterm", "cli", "activate-pane", "--pane-id", "12"]])
    }

    @Test func anythingElseNamesNoPane() {
        for environment in [
            [:], ["TMUX_PANE": "%3"], ["TMUX": "/tmp/t,1,0", "TMUX_PANE": "3"], ["TMUX": "relative,1,0", "TMUX_PANE": "%3"],
            ["TMUX": "/tmp/t,1,0", "TMUX_PANE": "%3;rm"], ["WEZTERM_PANE": "-1"], ["WEZTERM_PANE": ""],
        ] {
            #expect(TerminalPane(environment: environment) == nil, "\(environment)")
        }
    }

    @Test func theClientShowingTheSessionIsFound() {
        let clients = TerminalPane.clients(fromTmuxList: """
            101\t/dev/ttys001\twork\t1700000100
            102\t/dev/ttys002\tplay\t1700000300
            103\t/dev/ttys003\twork\t1700000200
            broken line
            """)
        #expect(clients.count == 3)
        #expect(TerminalPane.client(for: "work", among: clients)?.pid == 103)
        // No client on the session: the one used last, which a click switches over.
        #expect(TerminalPane.client(for: "other", among: clients)?.pid == 102)
        #expect(TerminalPane.client(for: "work", among: []) == nil)
    }

    @Test func thePaneShowsOnlyWhenActiveInAnAttachedSession() {
        #expect(TerminalPane.isShowing(tmuxDisplay: "1 1 1\n") == true)
        #expect(TerminalPane.isShowing(tmuxDisplay: "1 1 2") == true)
        #expect(TerminalPane.isShowing(tmuxDisplay: "0 1 1") == false)
        #expect(TerminalPane.isShowing(tmuxDisplay: "1 0 1") == false)
        #expect(TerminalPane.isShowing(tmuxDisplay: "1 1 0") == false)
        #expect(TerminalPane.isShowing(tmuxDisplay: "") == nil)
    }

    @Test func aCardKeepsThePaneOnlyWhenItBringsItsSenderForward() throws {
        let environment = try EnvironmentSettings(environment: [
            "__CFBundleIdentifier": "com.mitchellh.ghostty", "TMUX": "/tmp/t,1,0", "TMUX_PANE": "%2",
        ])
        let resolver = CardResolver(environment: environment)
        let card = try resolver.resolve(kind: "ok", title: "built", flags: CardFlags())
        #expect(card.pane?.tmuxPane == "%2")
        let elsewhere = try resolver.resolve(kind: "ok", title: "built", flags: CardFlags(activate: "com.apple.Safari"))
        #expect(elsewhere.pane == nil)
        let nowhere = try CardResolver(environment: try EnvironmentSettings(environment: ["TMUX": "/tmp/t,1,0", "TMUX_PANE": "%2"]))
            .resolve(kind: "ok", title: "built", flags: CardFlags())
        #expect(nowhere.pane == nil)
    }

    @Test func aTicketSaysWhenItWasQueued() {
        #expect(QueueTicket.queuedAt("01800000000500000000-42") == 1_800_000_000.5)
        #expect(QueueTicket.queuedAt("not-a-ticket") == nil)
    }
}
