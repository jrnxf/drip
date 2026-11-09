import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import Testing

struct ShellHookTests {
    static let block = ShellHook.snippet(for: .zsh)

    @Test func theBlockIsOneMarkedRegionThatEndsWithANewline() {
        #expect(Self.block.hasPrefix(ShellHook.begin + "\n"))
        #expect(Self.block.hasSuffix(ShellHook.end + "\n"))
        #expect(Self.block.components(separatedBy: "\n").filter { $0 == ShellHook.begin }.count == 1)
        // The defaults the docs promise.
        #expect(Self.block.contains("${DRIP_SLOW_AFTER:-10}"))
        for word in ["vim", "ssh", "less", "top", "python", "tmux"] {
            #expect(ShellHook.defaultIgnore.contains(word), "\(word)")
        }
    }

    @Test func theRcFileIsZshrcInZdotdirOrHome() {
        #expect(ShellHook.rcPath(for: .zsh, environment: ["HOME": "/home/user"]) == "/home/user/.zshrc")
        #expect(ShellHook.rcPath(for: .zsh, environment: ["HOME": "/home/user", "ZDOTDIR": "/home/user/.config/zsh"])
            == "/home/user/.config/zsh/.zshrc")
        #expect(ShellHook.rcPath(for: .zsh, environment: ["HOME": "/home/user", "ZDOTDIR": ""]) == "/home/user/.zshrc")
    }

    @Test func anEmptyOrMissingFileGetsTheBlock() throws {
        for text in [nil, ""] {
            let merge = try #require(try ShellHook.merge(text, shell: .zsh))
            #expect(merge.text == Self.block)
            #expect(!merge.updated)
        }
    }

    @Test func theBlockGoesAfterWhatIsThereSetOffByABlankLine() throws {
        for text in ["export A=1\n", "export A=1", "export A=1\n\n"] {
            let merge = try #require(try ShellHook.merge(text, shell: .zsh))
            #expect(merge.text == "export A=1\n\n" + Self.block, "\(text.debugDescription)")
        }
    }

    @Test func runningItAgainChangesNothing() throws {
        let once = try #require(try ShellHook.merge("export A=1\n", shell: .zsh)).text
        #expect(try ShellHook.merge(once, shell: .zsh) == nil)
        let after = once + "alias l='ls -l'\n"
        #expect(try ShellHook.merge(after, shell: .zsh) == nil)
    }

    @Test func anOutOfDateBlockIsReplacedWhereItStands() throws {
        let old = "\(ShellHook.begin)\n# an older drip\n\(ShellHook.end)\n"
        let merge = try #require(try ShellHook.merge("export A=1\n\(old)alias l='ls -l'\n", shell: .zsh))
        #expect(merge.text == "export A=1\n\(Self.block)alias l='ls -l'\n")
        #expect(merge.updated)
        // At the very end of a file with no newline after the block.
        let bare = try #require(try ShellHook.merge("\(ShellHook.begin)\nold\n\(ShellHook.end)", shell: .zsh))
        #expect(bare.text == Self.block)
    }

    @Test func aBlockCutInTwoOrDoubledIsLeftAlone() {
        for text in [
            "\(ShellHook.begin)\nno end\n", "no begin\n\(ShellHook.end)\n",
            "\(ShellHook.end)\n\(ShellHook.begin)\n", Self.block + Self.block,
        ] {
            #expect(throws: ShellHook.Refusal.self) { try ShellHook.merge(text, shell: .zsh) }
        }
    }

    @Test func setupZshIsParsedAsAShellNotAnAgent() throws {
        guard case let .invocation(.setup(setup)) = CommandLineParser.parse(["setup", "zsh"]) else {
            Issue.record(); return
        }
        #expect(setup.shell == .zsh)
        #expect(setup.agent == nil)
        guard case let .invocation(.setup(printing)) = CommandLineParser.parse(["setup", "zsh", "--print"]) else {
            Issue.record(); return
        }
        #expect(printing.printOnly)
        guard case let .invocation(.setup(claude)) = CommandLineParser.parse(["setup", "claude", "hooks.json"]) else {
            Issue.record(); return
        }
        #expect(claude.shell == nil)
        guard case let .exit(status, message) = CommandLineParser.parse(["setup", "zsh", "--remote"]) else {
            Issue.record(); return
        }
        #expect(status == ExitStatus.usage)
        #expect(message.hasPrefix("drip: --remote is for an agent's snippet"), "\(message)")
    }

    @Test func theFinishedCommandTakesTheCommandLineAfterTheDashes() throws {
        guard case let .invocation(.finished(command)) = CommandLineParser.parse([
            "__finished", "--status", "2", "--seconds", "12.5", "--", "make", "-j", "4", "test",
        ]) else { Issue.record(); return }
        #expect(command.status == 2)
        #expect(command.seconds == 12.5)
        #expect(command.command == "make -j 4 test")
        // A command line that starts with a dash is still the command line.
        guard case let .invocation(.finished(dashed)) = CommandLineParser.parse(
            ["__finished", "--status", "0", "--seconds", "11", "--", "--version"]) else { Issue.record(); return }
        #expect(dashed.command == "--version")
        guard case let .exit(status, _) = CommandLineParser.parse(["__finished", "--status", "0", "--seconds", "11"]) else {
            Issue.record(); return
        }
        #expect(status == ExitStatus.usage)
    }
}

#if !os(WASI)
/// Whether you are told about a slow command, by where the terminal it ran in is.
struct SlowCommandCardTests {
    func surroundings(
        _ front: WhenFocused.Front, paneShowing: Bool? = nil, gui: Bool = true, config: Config = Config(),
        environment extra: [String: String] = [:]
    ) -> AgentHook.Surroundings {
        AgentHook.Surroundings(
            environment: ["__CFBundleIdentifier": "com.apple.Terminal"].merging(extra) { $1 },
            hasGUISession: gui, isInstalled: { _ in false },
            front: { _ in front }, paneShowing: { _ in paneShowing },
            loadConfig: { _ in ConfigFile(config: config, warnings: []) },
            resolver: { file, environment in CardResolver(config: file.config, environment: try EnvironmentSettings(environment: environment)) })
    }

    func card(
        _ front: WhenFocused.Front, status: Int32 = 0, paneShowing: Bool? = nil, gui: Bool = true,
        config: Config = Config(), environment: [String: String] = [:]
    ) throws -> Card? {
        try ShellHook.card(
            command: "make test", status: status, seconds: 42.4,
            in: surroundings(front, paneShowing: paneShowing, gui: gui, config: config, environment: environment))
    }

    let away = WhenFocused.Front(app: false, idle: 1)

    @Test func theCardIsTheOneDripRunShows() throws {
        let ok = try #require(try card(away))
        #expect(ok.kind == "ok")
        #expect(ok.title == "make test finished")
        #expect(ok.detail == "42s")
        let fail = try #require(try card(away, status: 2))
        #expect(fail.kind == "fail")
        #expect(fail.title == "make test failed (exit 2)")
    }

    @Test func aTerminalYouAreWatchingGetsNoCard() throws {
        #expect(try card(WhenFocused.Front(app: true, idle: 3)) == nil)
        // The pane is the one showing.
        #expect(try card(WhenFocused.Front(app: true, idle: 3), paneShowing: true) == nil)
        #expect(try card(WhenFocused.Front(app: true, pane: true, idle: 3)) == nil)
    }

    @Test func aPaneThatIsNotShowingOrAnotherAppOrAnEmptyRoomGetsTheCard() throws {
        #expect(try card(WhenFocused.Front(app: true, idle: 3), paneShowing: false) != nil)
        #expect(try card(WhenFocused.Front(app: true, pane: false, idle: 3)) != nil)
        #expect(try card(WhenFocused.Front(app: false, idle: 3)) != nil)
        // The terminal is in front, but nobody has touched the keyboard or mouse for a while.
        #expect(try card(WhenFocused.Front(app: true, idle: 600)) != nil)
        #expect(try card(WhenFocused.Front(app: true, idle: 600), config: Config(awayAfter: 900)) == nil)
    }

    @Test func whenFocusedShowAlwaysShows() throws {
        #expect(try card(WhenFocused.Front(app: true, pane: true, idle: 1), config: Config(whenFocused: .show)) != nil)
        #expect(try card(WhenFocused.Front(app: true, pane: true, idle: 1), environment: ["DRIP_WHEN_FOCUSED": "show"]) != nil)
    }

    @Test func onlyDripHookOffKeepsItSilent() throws {
        // drip knows no other tool's variables: a tool that wants silence sets DRIP_HOOK=off.
        #expect(try card(away, environment: ["DRIP_HOOK": "off"]) == nil)
        #expect(try card(away, environment: ["DRIP_HOOK": "on"]) != nil)
    }

    @Test func withoutAGUISessionThereIsNoCard() throws {
        #expect(try card(away, gui: false) == nil)
    }
}

/// The zsh block itself, run by zsh with a stand-in for drip that records how it was called. Nothing is
/// shown on the screen.
struct ZshHookTests {
    static let zsh = ["/bin/zsh", "/usr/bin/zsh", "/opt/homebrew/bin/zsh", "/usr/local/bin/zsh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// A scratch directory with a `bin` that holds a fake drip.
    func scratch() throws -> (directory: String, calls: String) {
        let directory = NSTemporaryDirectory() + "drip-zsh-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory + "/bin", withIntermediateDirectories: true)
        let fake = directory + "/bin/drip"
        try """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(directory)/calls'
            """.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        return (directory, directory + "/calls")
    }

    /// Runs `script` in zsh with the block loaded and returns the fake drip's calls, one per line, and
    /// what the script printed.
    func run(
        _ script: String, environment: [String: String] = [:], dripOnPath: Bool = true
    ) throws -> (calls: [String], output: String) {
        let zsh = try #require(Self.zsh)
        let (directory, calls) = try scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // The hooks are called by hand below: left registered, zsh would run them for each line of the script too.
        let unhook = "add-zsh-hook -d preexec __drip_preexec; add-zsh-hook -d precmd __drip_precmd\n"
        try (ShellHook.snippet(for: .zsh) + unhook + script).write(toFile: directory + "/zshrc", atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zsh)
        process.arguments = ["-f", directory + "/zshrc"]
        var env = ["HOME": directory, "PATH": (dripOnPath ? directory + "/bin:" : "") + "/usr/bin:/bin"]
        env.merge(environment) { $1 }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // The fake drip is called in the background, after the shell is gone: wait for a call, or
        // long enough for one not to come.
        func logged() -> String { (try? String(contentsOfFile: calls, encoding: .utf8)) ?? "" }
        let deadline = Date().addingTimeInterval(5)
        while logged().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        // Time for a call that should not have come, or a second one.
        Thread.sleep(forTimeInterval: 0.2)
        return (logged().split(separator: "\n").map(String.init), String(decoding: data, as: UTF8.self))
    }

    /// A command line that ran for `seconds` and ended with `status`, as the shell's hooks see it:
    /// what was typed, then what it became after aliases, then the prompt.
    func command(_ typed: String, expanded: String? = nil, seconds: Double, status: Int = 0) -> String {
        """
        __drip_preexec '\(typed)' '\(expanded ?? typed)' '\(expanded ?? typed)'
        __drip_start=$(( EPOCHREALTIME - \(seconds) ))
        (exit \(status)); __drip_precmd
        """
    }

    @Test func aSlowCommandRunsDripOnceWithItsStatusTimeAndLine() throws {
        guard Self.zsh != nil else { return }
        let result = try run(command("make -j 4 test", seconds: 42, status: 2))
        try #require(result.calls.count == 1, "\(result)")
        let call = result.calls[0]
        #expect(call.hasPrefix("__finished --status 2 --seconds 4"), "\(call)")
        #expect(call.hasSuffix(" -- make -j 4 test"), "\(call)")
        #expect(result.output.isEmpty, "\(result.output)")
    }

    @Test func aFastCommandRunsNoDrip() throws {
        guard Self.zsh != nil else { return }
        let result = try run(command("ls", seconds: 9.5))
        #expect(result.calls.isEmpty, "\(result)")
    }

    @Test func theThresholdIsDripSlowAfter() throws {
        guard Self.zsh != nil else { return }
        #expect(try run(command("make", seconds: 20), environment: ["DRIP_SLOW_AFTER": "30"]).calls.isEmpty)
        #expect(try run(command("make", seconds: 4), environment: ["DRIP_SLOW_AFTER": "3"]).calls.count == 1)
        #expect(try run(command("make", seconds: 4), environment: ["DRIP_SLOW_AFTER": "0.5"]).calls.count == 1)
        // 0 turns the cards off.
        #expect(try run(command("make", seconds: 500), environment: ["DRIP_SLOW_AFTER": "0"]).calls.isEmpty)
    }

    @Test func commandsThatTakeTheTerminalGetNoCard() throws {
        guard Self.zsh != nil else { return }
        for line in [
            "vim notes.md", "ssh devbox", "less log.txt", "top", "python3", "/usr/bin/vim x",
            "sudo vim /etc/hosts", "FOO=1 BAR=2 less x", "env LANG=C man ls", "nohup htop", "command nvim", "'vim' x",
        ] {
            #expect(try run(command(line.replacingOccurrences(of: "'", with: "\\'"), seconds: 60)).calls.isEmpty, "\(line)")
        }
        // Not the first word of a command: only the command is looked at.
        #expect(try run(command("make vim", seconds: 60)).calls.count == 1)
        #expect(try run(command("echo ssh | less", seconds: 60)).calls.count == 1)
    }

    @Test func anAliasIsLookedAtForWhatItRuns() throws {
        guard Self.zsh != nil else { return }
        #expect(try run(command("v notes.md", expanded: "nvim notes.md", seconds: 60)).calls.isEmpty)
        let shown = try run(command("g", expanded: "git fetch --all", seconds: 60))
        #expect(shown.calls.count == 1)
        // The card is titled with what was typed.
        #expect(shown.calls.first?.hasSuffix(" -- g") == true, "\(shown)")
    }

    @Test func dripSlowIgnoreAddsToTheList() throws {
        guard Self.zsh != nil else { return }
        let environment = ["DRIP_SLOW_IGNORE": "make  deploy"]
        #expect(try run(command("make test", seconds: 60), environment: environment).calls.isEmpty)
        #expect(try run(command("deploy", seconds: 60), environment: environment).calls.isEmpty)
        #expect(try run(command("cargo build", seconds: 60), environment: environment).calls.count == 1)
        #expect(try run(command("vim x", seconds: 60), environment: environment).calls.isEmpty)
    }

    @Test func itStaysSilentWithoutDripOrWithDripHookOff() throws {
        guard Self.zsh != nil else { return }
        let slow = command("make", seconds: 60)
        let silent = try run(slow, dripOnPath: false)
        #expect(silent.calls.isEmpty)
        #expect(silent.output.isEmpty, "\(silent.output)")
        #expect(try run(slow, environment: ["DRIP_HOOK": "off"]).calls.isEmpty)
        #expect(try run(slow).calls.count == 1)
    }

    @Test func thePromptKeepsTheCommandsStatusAndAnEmptyLineCostsNothing() throws {
        guard Self.zsh != nil else { return }
        let result = try run("""
            \(command("make", seconds: 60, status: 3))
            __drip_preexec 'ls' 'ls' 'ls'
            (exit 7); __drip_precmd; print -r -- "status=$?"
            (exit 5); __drip_precmd; print -r -- "empty=$?"
            """)
        #expect(result.output.contains("status=7"), "\(result.output)")
        #expect(result.output.contains("empty=5"), "\(result.output)")
        #expect(result.calls.count == 1)
    }

    @Test func sourcingTheRcFileAgainWhileACommandRunsStartsNoCard() throws {
        guard Self.zsh != nil else { return }
        // `source ~/.zshrc` loads the block again between preexec and precmd: its start time must
        // stay the command's, not go back to zero, which would read as decades.
        let result = try run("""
            cat > "$HOME/block" <<'DRIP_TEST_BLOCK'
            \(ShellHook.snippet(for: .zsh))DRIP_TEST_BLOCK
            __drip_preexec 'source ~/.zshrc' 'source ~/.zshrc' 'source ~/.zshrc'; source "$HOME/block"; add-zsh-hook -d preexec __drip_preexec; add-zsh-hook -d precmd __drip_precmd
            (exit 0); __drip_precmd
            """, environment: ["DRIP_SLOW_AFTER": "5"])
        #expect(result.calls.isEmpty, "\(result)")
        #expect(result.output.isEmpty, "\(result.output)")
    }

    @Test func theUsersShellOptionsDoNotChangeTheHook() throws {
        guard Self.zsh != nil else { return }
        // A glob in the line stays text, and an unset DRIP_SLOW_IGNORE is no error under nounset.
        let line = "sleep 11; echo *"
        for options in ["setopt globsubst", "setopt shwordsplit", "setopt nounset", "setopt globsubst nounset shwordsplit"] {
            let result = try run("\(options)\n\(command(line, seconds: 60))")
            #expect(result.calls.count == 1, "\(options): \(result)")
            #expect(result.calls.first?.hasSuffix(" -- \(line)") == true, "\(options): \(result)")
            #expect(result.output.isEmpty, "\(options): \(result.output)")
        }
    }

    @Test func aThresholdThatIsNoNumberLeavesTheCardsOffQuietly() throws {
        guard Self.zsh != nil else { return }
        for after in ["10s", "abc", "-5", "1e3", "1."] {
            let result = try run(command("make", seconds: 60), environment: ["DRIP_SLOW_AFTER": after])
            #expect(result.calls.isEmpty, "\(after): \(result)")
            #expect(result.output.isEmpty, "\(after): \(result.output)")
        }
    }
}
#endif
