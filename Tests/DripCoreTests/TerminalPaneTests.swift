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
        // tmux inside another multiplexer: tmux's pane is the one drip selects.
        #expect(TerminalPane(environment: ["TMUX": "/tmp/t,1,0", "TMUX_PANE": "%1", "WEZTERM_PANE": "7"])?.tmuxPane == "%1")
    }

    @Test func aFailedSelectCommandSaysWhatTmuxSaid() {
        let command = ["tmux", "-S", "/tmp/t", "select-pane", "-t", "%3"]
        #expect(TerminalPane.selectFailure(command, stderr: "can't find pane: %3\nmore\n", reason: "exit status 1")
            == "cannot bring the agent's pane forward: tmux -S /tmp/t select-pane -t %3: can't find pane: %3")
        // Nothing on stderr: how it ended.
        #expect(TerminalPane.selectFailure(command, stderr: "", reason: "no answer within 1s")
            == "cannot bring the agent's pane forward: tmux -S /tmp/t select-pane -t %3: no answer within 1s")
    }

    @Test func otherTerminalsAndMultiplexersAreLeftToAClickCommand() {
        // WezTerm and herdr name their panes, but drip selects only tmux's: --on-click does the rest.
        for environment in [
            ["WEZTERM_PANE": "12"], ["HERDR_ENV": "1", "HERDR_PANE_ID": "w1:p2", "HERDR_TAB_ID": "w1:t2"],
        ] {
            #expect(TerminalPane(environment: environment) == nil, "\(environment)")
        }
    }

    @Test func anythingElseNamesNoPane() {
        for environment in [
            [:], ["TMUX_PANE": "%3"], ["TMUX": "/tmp/t,1,0", "TMUX_PANE": "3"], ["TMUX": "relative,1,0", "TMUX_PANE": "%3"],
            ["TMUX": "/tmp/t,1,0", "TMUX_PANE": "%3;rm"],
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
