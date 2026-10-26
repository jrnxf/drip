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

    @Test func herdrNamesItsPaneTabAndServer() throws {
        let environment = [
            "HERDR_ENV": "1", "HERDR_PANE_ID": "w1J:p2", "HERDR_TAB_ID": "w1J:t2", "HERDR_SOCKET_PATH": "/home/user/.config/herdr/herdr.sock",
        ]
        let pane = try #require(TerminalPane(environment: environment))
        #expect(pane == TerminalPane(herdrPane: "w1J:p2", herdrTab: "w1J:t2", herdrSocket: "/home/user/.config/herdr/herdr.sock"))
        let socket = "HERDR_SOCKET_PATH=/home/user/.config/herdr/herdr.sock"
        #expect(pane.selectCommands == [
            [socket, "herdr", "tab", "focus", "w1J:t2"],
            [socket, "herdr", "agent", "focus", "w1J:p2"],
        ])
        #expect(pane.herdrShowingCommand == [socket, "herdr", "pane", "get", "w1J:p2"])
        // Without a tab or a socket of its own: the agent, on herdr's default server.
        let bare = try #require(TerminalPane(environment: ["HERDR_ENV": "1", "HERDR_PANE_ID": "w1:p1", "HERDR_SOCKET_PATH": "relative"]))
        #expect(bare.selectCommands == [["herdr", "agent", "focus", "w1:p1"]])
        // tmux inside herdr: tmux's pane; herdr inside WezTerm: herdr's.
        #expect(TerminalPane(environment: environment.merging(["TMUX": "/tmp/t,1,0", "TMUX_PANE": "%1"]) { $1 })?.tmuxPane == "%1")
        #expect(TerminalPane(environment: environment.merging(["WEZTERM_PANE": "7"]) { $1 })?.herdrPane == "w1J:p2")
    }

    @Test func herdrSaysWhetherThePaneIsFocused() {
        #expect(TerminalPane.isShowing(herdrPane: #"{"id":"cli:pane:get","result":{"pane":{"focused":true,"pane_id":"w1:p2"}}}"#) == true)
        #expect(TerminalPane.isShowing(herdrPane: #"{"result":{"pane":{"focused":false}}}"#) == false)
        #expect(TerminalPane.isShowing(herdrPane: #"{"error":{"code":"pane_not_found"}}"#) == nil)
        #expect(TerminalPane.isShowing(herdrPane: "not json") == nil)
    }

    @Test func herdrNamesTheMachineItSavedForTheSSHTarget() {
        let list = #"""
            [
              {"id":"7fa0","label":"devbox.example.com","target":"devbox","enabled":true},
              {"id":"91bc","label":"build","target":"me@build.example.com:2222","enabled":true},
              {"id":"c3d4","label":"not a label","target":"odd","enabled":false}
            ]
            """#
        func machine(_ target: String, _ host: String?) -> String? {
            TerminalPane.herdrMachine(forSSHTarget: target, host: host, inList: list)
        }
        // Saved with that target, by its label.
        #expect(machine("devbox", "devbox") == "devbox.example.com")
        #expect(machine("me@build.example.com:2222", "build.example.com") == "build")
        // Labeled with the target, or with its host.
        #expect(machine("build", "build") == "build")
        #expect(machine("me@devbox.example.com", "devbox.example.com") == "devbox.example.com")
        // Saved with another target on the same host.
        #expect(machine("build.example.com", "build.example.com") == "build")
        // A label herdr would not take: its id.
        #expect(machine("odd", "odd") == "c3d4")
        #expect(machine("elsewhere", "elsewhere") == nil)
        #expect(TerminalPane.herdrMachine(forSSHTarget: "devbox", host: "devbox", inList: "error: no herdr") == nil)
        #expect(TerminalPane.herdrMachine(forSSHTarget: "devbox", host: nil, inList: "[]") == nil)
    }

    @Test func aFailedSelectCommandSaysWhatHerdrSaid() {
        let command = ["herdr", "--machine", "agents", "workspace", "focus", "wA6"]
        #expect(TerminalPane.selectFailure(
            command, stderr: "error: unknown machine 'agents'; use `herdr machine list`\nmore\n", reason: "exit status 1")
            == "cannot bring the agent's pane forward: herdr --machine agents workspace focus wA6: "
            + "error: unknown machine 'agents'; use `herdr machine list`")
        // Nothing on stderr: how it ended.
        #expect(TerminalPane.selectFailure(command, stderr: "", reason: "no answer within 5s")
            == "cannot bring the agent's pane forward: herdr --machine agents workspace focus wA6: no answer within 5s")
    }

    @Test func ghosttyBringsForwardTheTerminalThatShowsHerdrForTheMachine() throws {
        let pane = TerminalPane(herdrTab: "w1:t2", herdrMachine: "devbox.example.com", hostName: "devbox")
        let script = try #require(pane.ghosttyRaiseScript(localHost: "my-mac.local"))
        // herdr's title for a terminal showing the machine, then for one showing this Mac.
        #expect(script.contains(#"repeat with prefix in {"devbox: ", "my-mac.local: "}"#))
        #expect(script.contains(#"tell application id "com.mitchellh.ghostty""#))
        #expect(script.contains("focus candidate"))
        #expect(script.contains("with timeout of 4 seconds"))
        #expect(pane.ghosttyRaiseScript(localHost: nil)?.contains(#"{"devbox: "}"#) == true)
        // Quotes in this Mac's name stay inside the string.
        #expect(pane.ghosttyRaiseScript(localHost: #"odd"mac\"#)?.contains(#""odd\"mac\\: ""#) == true)
        // A pane on this Mac, or one without the machine's name: nothing for Ghostty to find.
        #expect(TerminalPane(herdrPane: "w1:p1").ghosttyRaiseScript(localHost: "my-mac.local") == nil)
        #expect(TerminalPane(herdrTab: "w1:t2", herdrMachine: "devbox").ghosttyRaiseScript(localHost: "my-mac.local") == nil)
        #expect(TerminalPane(herdrMachine: "devbox", hostName: "-x", environment: ["HERDR_TAB_ID": "w1:t2"])?.hostName == nil)
    }

    @Test func anythingElseNamesNoPane() {
        for environment in [
            [:], ["TMUX_PANE": "%3"], ["TMUX": "/tmp/t,1,0", "TMUX_PANE": "3"], ["TMUX": "relative,1,0", "TMUX_PANE": "%3"],
            ["TMUX": "/tmp/t,1,0", "TMUX_PANE": "%3;rm"], ["WEZTERM_PANE": "-1"], ["WEZTERM_PANE": ""],
            ["HERDR_PANE_ID": "w1:p2"], ["HERDR_ENV": "1", "HERDR_PANE_ID": "-w1"], ["HERDR_ENV": "1", "HERDR_PANE_ID": "w1;rm"],
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
