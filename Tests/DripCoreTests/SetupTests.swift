import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import Testing

struct SetupTests {
    @Test func everyRecipeSnippetIsOneDripCanInstall() throws {
        for name in Recipes.names {
            for agent in AgentHook.Agent.allCases {
                let snippet = try Recipes.snippet(name, agent)
                #expect(!snippet.events.isEmpty, "\(name) \(agent)")
                // The snippet's text is the file, as drip formats it.
                #expect(snippet.text == (try Recipes.text(name, agent)), "\(name) \(agent)")
            }
        }
    }

    @Test func theRecipesNameTheEventsEachAgentHas() throws {
        let everything = try Recipes.snippet("everything", .claude)
        #expect(everything.events.map(\.key) == [
            "PermissionRequest", "Notification", "Stop", "StopFailure",
            "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "ElicitationResult",
        ])
        // PermissionRequest shows permission prompts, with what Claude wants to do. Not idle_prompt,
        // whose card would replace the done card a minute after every turn.
        #expect(everything.events[1].value.elements?.first?["matcher"] == .string("elicitation_dialog"))
        #expect(try Recipes.snippet("everything", .codex).events.map(\.key)
            == ["PermissionRequest", "Stop", "PostToolUse", "UserPromptSubmit"])
        let gemini = try Recipes.snippet("everything", .gemini)
        #expect(gemini.events.map(\.key) == ["Notification", "AfterAgent", "AfterTool", "BeforeAgent"])
        // Gemini CLI enables and disables a hook by its name.
        #expect(gemini.events[1].value.elements?.first?["hooks"]?.elements?.first?["name"] == .string("drip"))

        // permission-cards has no Stop: the done card is not its policy.
        for agent in AgentHook.Agent.allCases {
            let keys = try Recipes.snippet("permission-cards", agent).events.map(\.key)
            #expect(!keys.contains("Stop") && !keys.contains("AfterAgent") && !keys.contains("StopFailure"), "\(agent)")
        }
        #expect(try Recipes.snippet("attention", .claude).events.map(\.key).contains("StopFailure"))
    }

    @Test func theRecipeFlagsAreOnTheCommandsTheyChange() throws {
        func commands(_ name: String, _ agent: AgentHook.Agent) throws -> [String: String] {
            Dictionary(uniqueKeysWithValues: try Recipes.snippet(name, agent).events.compactMap { event in
                event.value.elements?.first?["hooks"]?.elements?.first?["command"]?.string.map { (event.key, $0) }
            })
        }
        let approve = try commands("approve-from-card", .claude)
        #expect(approve["PermissionRequest"] == "drip hook claude --approve")
        #expect(approve["Notification"] == "drip hook claude")
        #expect(try commands("approve-from-card", .codex)["PermissionRequest"] == "drip hook codex --approve")
        let long = try commands("long-turns", .claude)
        #expect(long["Stop"] == "drip hook claude --min-turn 30")
        #expect(long["PermissionRequest"] == "drip hook claude")
        #expect(try commands("long-turns", .gemini)["AfterAgent"] == "drip hook gemini --min-turn 30")
    }

    @Test func aSnippetOfAnyOtherCommandIsRefused() {
        let other = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}"#
        #expect(throws: UsageError.self) { try AgentSetup.Snippet(parsing: other, agent: .claude) }
        // A command for another agent is not this agent's drip.
        let codex = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "drip hook codex"}]}]}}"#
        #expect(throws: UsageError.self) { try AgentSetup.Snippet(parsing: codex, agent: .claude) }
        for text in ["", "[1]", "{}", #"{"hooks": []}"#, #"{"hooks": {"Stop": {}}}"#, #"{"hooks": {"Stop": [{}]}}"#,
                     #"{"theme": 1, "hooks": {}}"#, "{\n // c\n}"] {
            #expect(throws: UsageError.self, "\(text)") { try AgentSetup.Snippet(parsing: text, agent: .claude) }
        }
        // An event with no groups has nothing to install.
        let empty = try? AgentSetup.Snippet(parsing: #"{"hooks": {"Stop": []}}"#, agent: .claude)
        #expect(empty?.events.isEmpty == true)
    }

    @Test func remoteChangesTheCommandAndKeepsTheFlags() throws {
        let snippet = try Recipes.snippet("long-turns", .claude).remote()
        #expect(snippet.text.contains(#""command": "drip-remote-hook claude --min-turn 30""#))
        #expect(snippet.text.contains(#""command": "drip-remote-hook claude""#))
        #expect(!snippet.text.contains("drip hook"))
        #expect(try Recipes.snippet("everything", .gemini).remote().text.contains(#""name": "drip""#))
    }

    @Test func anEmptyOrMissingFileGetsTheSnippet() throws {
        for text in [nil, "", "  \n"] {
            for agent in AgentHook.Agent.allCases {
                let snippet = try Recipes.snippet("everything", agent)
                let merge = try #require(try AgentSetup.merge(text, snippet: snippet))
                #expect(merge.text == snippet.text)
                #expect(merge.installed == snippet.events.map(\.key))
                #expect(merge.removed.isEmpty)
            }
        }
    }

    @Test func mergingKeepsEverythingElseInOrder() throws {
        let text = """
            {
                "model": "opus",
                "hooks": {
                    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "lint"}]}],
                    "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
                },
                "permissions": {"allow": ["Bash(ls:*)"]},
                "cleanupPeriodDays": 30.0
            }
            """
        let snippet = try Recipes.snippet("everything", .claude)
        let merge = try #require(try AgentSetup.merge(text, snippet: snippet))
        #expect(merge.installed == snippet.events.map(\.key))
        let value = try JSONValue(parsing: merge.text)
        #expect(value.members?.map(\.key) == ["model", "hooks", "permissions", "cleanupPeriodDays"])
        #expect(value["hooks"]?.members?.map(\.key) == [
            "PreToolUse", "Stop", "PermissionRequest", "Notification", "StopFailure", "PostToolUse",
            "PostToolUseFailure", "UserPromptSubmit", "ElicitationResult",
        ])
        // The other Stop hook stays, and drip's goes after it.
        #expect(value["hooks"]?["Stop"]?.elements?.count == 2)
        #expect(value["hooks"]?["Stop"]?.elements?.first?["hooks"]?.elements?.first?["command"] == .string("say done"))
        #expect(value["cleanupPeriodDays"] == .number("30.0"))
        // The file's own indent, and no newline at the end since it had none.
        #expect(merge.text.contains("\n    \"model\": \"opus\""))
        #expect(merge.text.hasSuffix("}"))
        #expect(try AgentSetup.merge(merge.text, snippet: snippet) == nil)
    }

    @Test func runningItAgainChangesNothing() throws {
        for agent in AgentHook.Agent.allCases {
            let snippet = try Recipes.snippet("attention", agent)
            let once = try #require(try AgentSetup.merge(#"{"theme": "dark"}"#, snippet: snippet))
            #expect(try AgentSetup.merge(once.text, snippet: snippet) == nil, "\(agent)")
        }
    }

    /// Another recipe takes the place of the one before: drip's hooks are replaced, not added to.
    @Test func aNewRecipeReplacesDripsOldHooksAndLeavesTheRest() throws {
        let everything = try Recipes.snippet("everything", .claude)
        let cards = try Recipes.snippet("permission-cards", .claude)
        let start = """
            {"hooks": {
              "Stop": [{"hooks": [{"type": "command", "command": "say hi"}, {"type": "command", "command": "drip hook claude"}]}],
              "PreToolUse": [{"hooks": [{"type": "command", "command": "lint"}]}]
            }}
            """
        let full = try #require(try AgentSetup.merge(start, snippet: everything))
        let narrow = try #require(try AgentSetup.merge(full.text, snippet: cards))
        #expect(narrow.removed == ["Stop", "StopFailure"])
        let value = try JSONValue(parsing: narrow.text)
        let keys = value["hooks"]?.members?.map(\.key) ?? []
        #expect(!keys.contains("StopFailure"))
        // The person's own Stop hook is still there, alone.
        #expect(value["hooks"]?["Stop"]?.elements?.count == 1)
        #expect(value["hooks"]?["Stop"]?.elements?.first?["hooks"]?.elements?.first?["command"] == .string("say hi"))
        #expect(value["hooks"]?["PreToolUse"] != nil)
        #expect(try AgentSetup.merge(narrow.text, snippet: cards) == nil)
        // A flag change replaces the command where it stands.
        let approve = try Recipes.snippet("approve-from-card", .claude)
        let flagged = try #require(try AgentSetup.merge(narrow.text, snippet: approve))
        #expect(flagged.installed == ["PermissionRequest"])
        #expect(flagged.text.contains("drip hook claude --approve"))
    }

    /// A hook that already runs drip counts, whatever path names drip, so drip is never added twice.
    @Test func drippedHooksAreFound() throws {
        let text = """
            {"hooks": {
              "Notification": [{"matcher": "permission_prompt", "hooks": [{"type": "command", "command": "/opt/homebrew/bin/drip hook claude --quiet"}]}]
            }}
            """
        let merge = try #require(try AgentSetup.merge(text, snippet: try Recipes.snippet("permission-cards", .claude)))
        // The old drip hook on Notification is replaced by the snippet's.
        let notification = try JSONValue(parsing: merge.text)["hooks"]?["Notification"]?.elements
        #expect(notification?.count == 1)
        #expect(notification?.first?["matcher"] == .string("elicitation_dialog"))
        #expect(AgentSetup.runsDrip(command: "'drip' hook codex", agent: .codex))
        #expect(!AgentSetup.runsDrip(command: "drip hook claude", agent: .codex))
        #expect(!AgentSetup.runsDrip(command: "dripper hook claude", agent: .claude))
        #expect(!AgentSetup.runsDrip(command: "drip ok hook claude", agent: .claude))
    }

    @Test func aFileDripCannotReadIsLeftAlone() throws {
        let snippet = try Recipes.snippet("everything", .claude)
        let refused = [
            "{\n  // comments\n  \"a\": 1\n}", #"{"a": 1,}"#, "[1, 2]", #""text""#, #"{"hooks": []}"#,
            #"{"hooks": {"Stop": {"hooks": []}}}"#,
        ]
        for text in refused {
            #expect(throws: AgentSetup.Refusal.self, "\(text)") { try AgentSetup.merge(text, snippet: snippet) }
        }
        #expect(throws: AgentSetup.Refusal(description: "is not plain JSON (line 2: comments are not JSON)")) {
            try AgentSetup.merge("{\n  // comments\n  \"a\": 1\n}", snippet: snippet)
        }
    }

    @Test func settingsPathsFollowTheEnvironment() {
        let home = ["HOME": "/home/user"]
        #expect(AgentSetup.settingsPath(for: .claude, environment: home) == "/home/user/.claude/settings.json")
        #expect(AgentSetup.settingsPath(for: .codex, environment: home) == "/home/user/.codex/hooks.json")
        #expect(AgentSetup.settingsPath(for: .gemini, environment: home) == "/home/user/.gemini/settings.json")
        #expect(AgentSetup.codexConfigPath(environment: home) == "/home/user/.codex/config.toml")
        let moved = ["HOME": "/home/user", "CLAUDE_CONFIG_DIR": "/cfg/claude", "CODEX_HOME": "/cfg/codex"]
        #expect(AgentSetup.settingsPath(for: .claude, environment: moved) == "/cfg/claude/settings.json")
        #expect(AgentSetup.settingsPath(for: .codex, environment: moved) == "/cfg/codex/hooks.json")
        #expect(AgentSetup.codexConfigPath(environment: moved) == "/cfg/codex/config.toml")
    }

    @Test func codexNotifyThatRunsDripIsFound() {
        let config = CodexConfig("""
            model = "gpt-5.5"
            notify = ["drip", "hook", "codex"]  # cards

            [tui]
            notifications = true
            """)
        #expect(config.dripNotify == 1..<2)
        #expect(!config.otherDripNotify)
        #expect(config.withoutDripNotify == "model = \"gpt-5.5\"\n\n[tui]\nnotifications = true")

        let multiline = CodexConfig("notify = [\n  '/opt/homebrew/bin/drip',\n  'hook',\n  'codex',\n]\nmodel = 'x'\n")
        #expect(multiline.dripNotify == 0..<5)
        #expect(multiline.withoutDripNotify == "model = 'x'\n")

        // Anything else that runs drip from notify is the user's to change.
        let wrapped = CodexConfig(#"notify = ["sh", "-c", "drip hook codex \"$1\"; say done", "--"]"#)
        #expect(wrapped.dripNotify == nil)
        #expect(wrapped.otherDripNotify)
        // A notify inside a table is something else.
        let nested = CodexConfig("[tui]\nnotify = [\"drip\", \"hook\", \"codex\"]\n")
        #expect(nested.dripNotify == nil)
        #expect(!nested.otherDripNotify)
        #expect(CodexConfig("notify = [\"terminal-notifier\"]\n").dripNotify == nil)
    }

    @Test func codexHooksInConfigTomlCountByEvent() {
        #expect(CodexConfig("""
            [[hooks.Stop]]
            [[hooks.Stop.hooks]]
            type = "command"
            command = "drip hook codex"

            [[hooks.PermissionRequest]]  # approvals
            [[hooks.PermissionRequest.hooks]]
            command = "/opt/homebrew/bin/drip hook codex"

            [[hooks.SessionStart]]
            [[hooks.SessionStart.hooks]]
            command = "say hi"
            """).dripHookEvents == ["Stop", "PermissionRequest"])
        #expect(CodexConfig("[profiles.x]\ncommand = \"drip hook codex\"\n").dripHookEvents.isEmpty)
    }

    @Test func codexConfigSkipsWhatIsInsideMultiLineStrings() {
        let basic = CodexConfig(#"""
            developer_instructions = """
            [important] always run tests
            hooks.Stop = "drip hook codex" and a \""" that is not the end
            """
            notify = ["drip", "hook", "codex"]
            """#)
        #expect(basic.dripNotify == 4..<5)
        #expect(basic.dripHookEvents.isEmpty)

        let literal = CodexConfig("""
            model_instructions = '''one line with [brackets] = and '''
            developer_instructions = '''
            [hooks]
            Stop = [{ hooks = [{ command = "drip hook codex" }] }]
            notify = ["drip", "hook", "codex"]
            '''
            notify = ["drip", "hook", "codex"]
            """)
        #expect(literal.dripNotify == 6..<7)
        #expect(literal.dripHookEvents.isEmpty)
    }

    @Test func codexInlineHooksInConfigTomlCountByEvent() {
        // A [hooks] table names the event by its key, with a value that may run over several lines.
        #expect(CodexConfig("""
            [hooks]
            Stop = [{ hooks = [{ type = "command", command = "drip hook codex" }] }]
            PermissionRequest = [
              # approvals
              { hooks = [{ type = "command", command = "drip hook codex" }] },
            ]
            SessionStart = [{ hooks = [{ type = "command", command = "say hi" }] }]
            """).dripHookEvents == ["Stop", "PermissionRequest"])
        // So does a dotted key outside any table.
        #expect(CodexConfig("""
            model = "gpt-5.5"
            hooks.Stop = [{ hooks = [{ type = "command", command = "/usr/local/bin/drip hook codex" }] }]

            [tui]
            notifications = true
            """).dripHookEvents == ["Stop"])
    }
}

#if !os(WASI)
/// `drip setup` against files in a scratch home directory.
struct SetupInstallerTests {
    let home: String
    let installer: SetupInstaller

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("drip-setup-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        // 2026-10-21 17:15:00 wherever the tests run: the backup's name is local time.
        let now = DateComponents(year: 2026, month: 10, day: 21, hour: 17, minute: 15)
        installer = SetupInstaller(environment: ["HOME": home], now: Calendar.current.date(from: now) ?? Date())
    }

    func file(_ path: String) -> String? {
        try? String(contentsOfFile: "\(home)/\(path)", encoding: .utf8)
    }

    func write(_ text: String, to path: String) throws {
        let full = "\(home)/\(path)"
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: false, encoding: .utf8)
    }

    /// What setup says about Claude Code's own notifications.
    static let claudeNotifies = "Claude Code can also notify you itself, through your terminal: if each card comes "
        + "with a second notification, set Local notifications to disabled in its /config."

    func backups(in directory: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: "\(home)/\(directory)").filter { $0.contains(".drip-backup-") }.sorted()
    }

    /// The snippet of a recipe, as an installer takes it.
    func recipe(_ name: String, _ agent: AgentHook.Agent) throws -> AgentSetup.Snippet {
        try Recipes.snippet(name, agent)
    }

    @Test func createsTheFileAndItsDirectory() throws {
        let snippet = try recipe("everything", .gemini)
        #expect(installer.install(snippet) == .done(lines: [
            "Put drip's Notification, AfterAgent, AfterTool and BeforeAgent hooks in ~/.gemini/settings.json.",
        ], warnings: []))
        #expect(file(".gemini/settings.json") == snippet.text)
        #expect(try backups(in: ".gemini").isEmpty)
    }

    @Test func backsUpAndKeepsThePermissions() throws {
        let original = "{\n  \"theme\": \"dark\"\n}\n"
        try write(original, to: ".claude/settings.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: "\(home)/.claude/settings.json")
        let snippet = try recipe("everything", .claude)
        #expect(installer.install(snippet) == .done(lines: [
            "Put drip's PermissionRequest, Notification, Stop, StopFailure, PostToolUse, PostToolUseFailure, "
                + "UserPromptSubmit and ElicitationResult hooks in ~/.claude/settings.json.",
            "Backed up the old settings.json to ~/.claude/settings.json.drip-backup-20261021-171500.",
            Self.claudeNotifies,
        ], warnings: []))
        #expect(file(".claude/settings.json.drip-backup-20261021-171500") == original)
        let attributes = try FileManager.default.attributesOfItem(atPath: "\(home)/.claude/settings.json")
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try JSONValue(parsing: file(".claude/settings.json") ?? "")["theme"] == .string("dark"))
        // No temporary file is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(home)/.claude").sorted()
            == ["settings.json", "settings.json.drip-backup-20261021-171500"])

        // Again: nothing to do, no write and no second backup.
        #expect(installer.install(snippet) == .done(
            lines: ["drip's hooks in ~/.claude/settings.json are the snippet's already.", Self.claudeNotifies], warnings: []))
        #expect(try backups(in: ".claude").count == 1)
    }

    @Test func anotherRecipeTakesTheOldOnesHooksOut() throws {
        _ = installer.install(try recipe("everything", .claude))
        #expect(installer.install(try recipe("permission-cards", .claude)) == .done(lines: [
            "Took drip's Stop and StopFailure hooks out of ~/.claude/settings.json.",
            "Backed up the old settings.json to ~/.claude/settings.json.drip-backup-20261021-171500.",
            Self.claudeNotifies,
        ], warnings: []))
        let events = try JSONValue(parsing: file(".claude/settings.json") ?? "")["hooks"]?.members?.map(\.key)
        #expect(events == ["PermissionRequest", "Notification", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "ElicitationResult"])
    }

    @Test func aSecondBackupInTheSameSecondIsNumbered() throws {
        try write("{}", to: ".codex/hooks.json")
        try write("{}", to: ".codex/hooks.json.drip-backup-20261021-171500")
        _ = installer.install(try recipe("everything", .codex))
        #expect(try backups(in: ".codex") == ["hooks.json.drip-backup-20261021-171500", "hooks.json.drip-backup-20261021-171500-2"])
    }

    /// A symlink, as home-manager makes, is never written through or replaced.
    @Test func aSymlinkIsLeftAlone() throws {
        let snippet = try recipe("everything", .claude)
        try write(#"{"theme": "dark"}"#, to: "dotfiles/settings.json")
        try FileManager.default.createDirectory(atPath: "\(home)/.claude", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: "\(home)/.claude/settings.json", withDestinationPath: "\(home)/dotfiles/settings.json")
        #expect(installer.install(snippet) == .refused(
            reason: "~/.claude/settings.json is a symlink, as home-manager and other dotfile managers make, so drip "
                + "leaves it alone: add these hooks where it comes from.",
            snippet: snippet.text))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(home)/.claude/settings.json")
            == "\(home)/dotfiles/settings.json")
        #expect(file("dotfiles/settings.json") == #"{"theme": "dark"}"#)
        #expect(try backups(in: ".claude").isEmpty)

        // One that already holds the snippet's hooks needs nothing, so it is fine.
        try write(snippet.text, to: "dotfiles/settings.json")
        #expect(installer.install(snippet) == .done(
            lines: ["drip's hooks in ~/.claude/settings.json are the snippet's already.", Self.claudeNotifies], warnings: []))
    }

    @Test func aReadOnlyFileIsLeftAlone() throws {
        try write("{}", to: ".gemini/settings.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: "\(home)/.gemini/settings.json")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: "\(home)/.gemini/settings.json") }
        // root may write anything, so the check means nothing there.
        guard !FileManager.default.isWritableFile(atPath: "\(home)/.gemini/settings.json") else { return }
        guard case let .refused(reason, _) = installer.install(try recipe("everything", .gemini)) else { Issue.record(); return }
        #expect(reason.hasPrefix("~/.gemini/settings.json is read-only, so drip leaves it alone"))
        #expect(file(".gemini/settings.json") == "{}")
    }

    @Test func codexMovesFromNotifyToHooks() throws {
        try write("model = \"gpt-5.5\"\nnotify = [\"drip\", \"hook\", \"codex\"]\n", to: ".codex/config.toml")
        let snippet = try recipe("everything", .codex)
        #expect(installer.install(snippet) == .done(lines: [
            "Put drip's PermissionRequest, Stop, PostToolUse and UserPromptSubmit hooks in ~/.codex/hooks.json.",
            "Removed notify from ~/.codex/config.toml: the hooks show the cards instead.",
            "Backed up the old config.toml to ~/.codex/config.toml.drip-backup-20261021-171500.",
            "Codex runs a new hook only once you trust it: run /hooks in Codex.",
        ], warnings: []))
        #expect(file(".codex/config.toml") == "model = \"gpt-5.5\"\n")
        #expect(file(".codex/hooks.json") == snippet.text)
    }

    @Test func codexNotifyInASymlinkedConfigStopsEverything() throws {
        try write("notify = [\"drip\", \"hook\", \"codex\"]\n", to: "dotfiles/config.toml")
        try FileManager.default.createDirectory(atPath: "\(home)/.codex", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: "\(home)/.codex/config.toml", withDestinationPath: "\(home)/dotfiles/config.toml")
        let snippet = try recipe("everything", .codex)
        guard case let .refused(reason, shown) = installer.install(snippet) else { Issue.record(); return }
        #expect(reason.hasPrefix("~/.codex/config.toml is a symlink"))
        #expect(reason.contains("notify"))
        #expect(shown == snippet.text)
        // Neither file changed: hooks alone would show every done card twice.
        #expect(file(".codex/hooks.json") == nil)
        #expect(file("dotfiles/config.toml") == "notify = [\"drip\", \"hook\", \"codex\"]\n")
    }

    @Test func codexWarnsAboutANotifyItCannotChange() throws {
        try write(#"notify = ["sh", "-c", "drip hook codex \"$1\""]"# + "\n", to: ".codex/config.toml")
        guard case let .done(_, warnings) = installer.install(try recipe("everything", .codex)) else { Issue.record(); return }
        #expect(warnings == [
            "the notify in ~/.codex/config.toml runs drip too: take drip out of it, or every done card shows twice",
        ])
        #expect(file(".codex/config.toml") == #"notify = ["sh", "-c", "drip hook codex \"$1\""]"# + "\n")
    }

    @Test func codexWarnsAboutAnEventThatRunsDripInBothFiles() throws {
        let snippet = try recipe("everything", .codex)
        try write("[hooks]\nStop = [{ hooks = [{ command = \"drip hook codex\" }] }]\n", to: ".codex/config.toml")
        try write(snippet.text, to: ".codex/hooks.json")
        #expect(installer.install(snippet) == .done(lines: [
            "drip's hooks in ~/.codex/hooks.json are the snippet's already.",
        ], warnings: [
            "~/.codex/config.toml and ~/.codex/hooks.json both run drip on Stop: take it out of one, "
                + "or every Stop card shows twice",
        ]))
        #expect(file(".codex/hooks.json") == snippet.text)
        #expect(try backups(in: ".codex").isEmpty)
    }

    @Test func codexNamesWhatChangedWhenALaterWriteFails() throws {
        try write("notify = [\"drip\", \"hook\", \"codex\"]\n", to: ".codex/config.toml")
        // A directory in the way of hooks.json's temporary file fails its write after config.toml's.
        let temporary = "\(home)/.codex/.hooks.json.drip-\(ProcessInfo.processInfo.processIdentifier)"
        try FileManager.default.createDirectory(atPath: temporary, withIntermediateDirectories: true)
        guard case let .failed(message) = installer.install(try recipe("everything", .codex)) else { Issue.record(); return }
        #expect(message.hasPrefix("could not write ~/.codex/hooks.json: "))
        #expect(message.hasSuffix("; drip already changed ~/.codex/config.toml, backed up to "
            + "~/.codex/config.toml.drip-backup-20261021-171500"))
        // The notify is gone, so no done card shows twice.
        #expect(file(".codex/config.toml") == "")
    }

    @Test func notJSONIsLeftAlone() throws {
        let snippet = try recipe("everything", .gemini)
        try write("{\n  // mine\n}\n", to: ".gemini/settings.json")
        #expect(installer.install(snippet) == .refused(
            reason: "~/.gemini/settings.json is not plain JSON (line 2: comments are not JSON), so drip leaves it alone: "
                + "add these hooks to it yourself.",
            snippet: snippet.text))
        #expect(file(".gemini/settings.json") == "{\n  // mine\n}\n")
    }
}
#endif
