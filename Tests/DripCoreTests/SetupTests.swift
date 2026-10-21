import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import Testing

struct SetupTests {
    @Test func theSnippetIsEachAgentsHooks() throws {
        let claude = try JSONValue(parsing: AgentSetup.snippet(for: .claude))
        #expect(claude["hooks"]?.members?.map(\.key) == ["Notification", "Stop", "StopFailure"])
        // Not idle_prompt, whose card would replace the done card a minute after every turn.
        #expect(claude["hooks"]?["Notification"]?.elements?.first?["matcher"] == .string("permission_prompt|elicitation_dialog"))
        #expect(claude["hooks"]?["Stop"]?.elements?.first?["matcher"] == nil)
        #expect(claude["hooks"]?["Stop"]?.elements?.first?["hooks"] == .array([.object([
            JSONMember("type", .string("command")), JSONMember("command", .string("drip hook claude")),
        ])]))

        let codex = try JSONValue(parsing: AgentSetup.snippet(for: .codex))
        #expect(codex["hooks"]?.members?.map(\.key) == ["PermissionRequest", "Stop"])
        let gemini = try JSONValue(parsing: AgentSetup.snippet(for: .gemini))
        #expect(gemini["hooks"]?.members?.map(\.key) == ["Notification", "AfterAgent"])
        // Gemini CLI enables and disables a hook by its name.
        #expect(gemini["hooks"]?["AfterAgent"]?.elements?.first?["hooks"]?.elements?.first?["name"] == .string("drip"))
        #expect(AgentSetup.snippet(for: .gemini).hasSuffix("}\n"))
    }

    @Test func anEmptyOrMissingFileGetsTheSnippet() throws {
        for text in [nil, "", "  \n"] {
            for agent in AgentHook.Agent.allCases {
                let merge = try #require(try AgentSetup.merge(text, agent: agent))
                #expect(merge.text == AgentSetup.snippet(for: agent))
                #expect(merge.updated.isEmpty)
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
        let merge = try #require(try AgentSetup.merge(text, agent: .claude))
        #expect(merge.added == ["Notification", "Stop", "StopFailure"])
        let value = try JSONValue(parsing: merge.text)
        #expect(value.members?.map(\.key) == ["model", "hooks", "permissions", "cleanupPeriodDays"])
        #expect(value["hooks"]?.members?.map(\.key) == ["PreToolUse", "Stop", "Notification", "StopFailure"])
        // The other Stop hook stays, and drip's goes after it.
        #expect(value["hooks"]?["Stop"]?.elements?.count == 2)
        #expect(value["hooks"]?["Stop"]?.elements?.first?["hooks"]?.elements?.first?["command"] == .string("say done"))
        #expect(value["cleanupPeriodDays"] == .number("30.0"))
        // The file's own indent, and no newline at the end since it had none.
        #expect(merge.text.contains("\n    \"model\": \"opus\""))
        #expect(merge.text.hasSuffix("}"))
        #expect(try AgentSetup.merge(merge.text, agent: .claude) == nil)
    }

    @Test func runningItAgainChangesNothing() throws {
        for agent in AgentHook.Agent.allCases {
            let once = try #require(try AgentSetup.merge(#"{"theme": "dark"}"#, agent: agent))
            #expect(try AgentSetup.merge(once.text, agent: agent) == nil, "\(agent)")
        }
    }

    /// A hook that already runs drip counts, whatever path names drip, so drip is never added twice.
    @Test func drippedHooksAreFound() throws {
        let text = """
            {"hooks": {
              "Notification": [{"matcher": "permission_prompt", "hooks": [{"type": "command", "command": "/opt/homebrew/bin/drip hook claude --quiet"}]}],
              "Stop": [{"hooks": [{"type": "command", "command": "say hi"}, {"type": "command", "command": "drip hook claude"}]}]
            }}
            """
        let merge = try #require(try AgentSetup.merge(text, agent: .claude))
        #expect(merge.added == ["StopFailure"])
        #expect(merge.updated.isEmpty)
        // The matcher someone chose is theirs.
        #expect(try JSONValue(parsing: merge.text)["hooks"]?["Notification"]?.elements?.first?["matcher"]
            == .string("permission_prompt"))
        #expect(AgentSetup.runsDrip(command: "'drip' hook codex", agent: .codex))
        #expect(!AgentSetup.runsDrip(command: "drip hook claude", agent: .codex))
        #expect(!AgentSetup.runsDrip(command: "dripper hook claude", agent: .claude))
        #expect(!AgentSetup.runsDrip(command: "drip ok hook claude", agent: .claude))
    }

    /// The matcher the README recommended before moves to the new one, without idle_prompt.
    @Test func theOldMatcherIsUpdated() throws {
        let text = """
            {"hooks": {"Notification": [{"matcher": "permission_prompt|idle_prompt|elicitation_dialog",
              "hooks": [{"type": "command", "command": "drip hook claude"}]}],
              "Stop": [{"hooks": [{"type": "command", "command": "drip hook claude"}]}]}}
            """
        let merge = try #require(try AgentSetup.merge(text, agent: .claude))
        #expect(merge.added == ["StopFailure"])
        #expect(merge.updated == ["Notification"])
        let notification = try JSONValue(parsing: merge.text)["hooks"]?["Notification"]?.elements
        #expect(notification?.count == 1)
        #expect(notification?.first?.members?.map(\.key) == ["matcher", "hooks"])
        #expect(notification?.first?["matcher"] == .string("permission_prompt|elicitation_dialog"))
        // Shared with another hook, the group is left as it is.
        let shared = """
            {"hooks": {"Notification": [{"matcher": "permission_prompt|idle_prompt|elicitation_dialog",
              "hooks": [{"type": "command", "command": "drip hook claude"}, {"type": "command", "command": "say hi"}]}]}}
            """
        #expect(try #require(try AgentSetup.merge(shared, agent: .claude)).updated.isEmpty)
    }

    @Test func aFileDripCannotReadIsLeftAlone() {
        let refused = [
            "{\n  // comments\n  \"a\": 1\n}", #"{"a": 1,}"#, "[1, 2]", #""text""#, #"{"hooks": []}"#,
            #"{"hooks": {"Stop": {"hooks": []}}}"#,
        ]
        for text in refused {
            #expect(throws: AgentSetup.Refusal.self, "\(text)") { try AgentSetup.merge(text, agent: .claude) }
        }
        #expect(throws: AgentSetup.Refusal(description: "is not plain JSON (line 2: comments are not JSON)")) {
            try AgentSetup.merge("{\n  // comments\n  \"a\": 1\n}", agent: .gemini)
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

    @Test func mergeSkipsEventsThatRunDripElsewhere() throws {
        let merge = try #require(try AgentSetup.merge(nil, agent: .codex, skipping: ["Stop"]))
        #expect(merge.added == ["PermissionRequest"])
        #expect(try JSONValue(parsing: merge.text)["hooks"]?.members?.map(\.key) == ["PermissionRequest"])
        #expect(try AgentSetup.merge(nil, agent: .codex, skipping: ["PermissionRequest", "Stop"]) == nil)
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

    func backups(in directory: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: "\(home)/\(directory)").filter { $0.contains(".drip-backup-") }.sorted()
    }

    @Test func createsTheFileAndItsDirectory() throws {
        #expect(installer.install(.gemini) == .done(lines: [
            "Added drip's Notification and AfterAgent hooks to ~/.gemini/settings.json.",
        ], warnings: []))
        #expect(file(".gemini/settings.json") == AgentSetup.snippet(for: .gemini))
        #expect(try backups(in: ".gemini").isEmpty)
    }

    @Test func backsUpAndKeepsThePermissions() throws {
        let original = "{\n  \"theme\": \"dark\"\n}\n"
        try write(original, to: ".claude/settings.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: "\(home)/.claude/settings.json")
        #expect(installer.install(.claude) == .done(lines: [
            "Added drip's Notification, Stop and StopFailure hooks to ~/.claude/settings.json.",
            "Backed up the old settings.json to ~/.claude/settings.json.drip-backup-20261021-171500.",
        ], warnings: []))
        #expect(file(".claude/settings.json.drip-backup-20261021-171500") == original)
        let attributes = try FileManager.default.attributesOfItem(atPath: "\(home)/.claude/settings.json")
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try JSONValue(parsing: file(".claude/settings.json") ?? "")["theme"] == .string("dark"))
        // No temporary file is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(home)/.claude").sorted()
            == ["settings.json", "settings.json.drip-backup-20261021-171500"])

        // Again: nothing to do, no write and no second backup.
        #expect(installer.install(.claude) == .done(lines: ["drip's hooks are already in ~/.claude/settings.json."], warnings: []))
        #expect(try backups(in: ".claude").count == 1)
    }

    @Test func aSecondBackupInTheSameSecondIsNumbered() throws {
        try write("{}", to: ".codex/hooks.json")
        try write("{}", to: ".codex/hooks.json.drip-backup-20261021-171500")
        _ = installer.install(.codex)
        #expect(try backups(in: ".codex") == ["hooks.json.drip-backup-20261021-171500", "hooks.json.drip-backup-20261021-171500-2"])
    }

    /// A symlink, as home-manager makes, is never written through or replaced.
    @Test func aSymlinkIsLeftAlone() throws {
        try write(#"{"theme": "dark"}"#, to: "dotfiles/settings.json")
        try FileManager.default.createDirectory(atPath: "\(home)/.claude", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: "\(home)/.claude/settings.json", withDestinationPath: "\(home)/dotfiles/settings.json")
        #expect(installer.install(.claude) == .refused(
            reason: "~/.claude/settings.json is a symlink, as home-manager and other dotfile managers make, so drip "
                + "leaves it alone: add these hooks where it comes from.",
            snippet: AgentSetup.snippet(for: .claude)))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(home)/.claude/settings.json")
            == "\(home)/dotfiles/settings.json")
        #expect(file("dotfiles/settings.json") == #"{"theme": "dark"}"#)
        #expect(try backups(in: ".claude").isEmpty)

        // One that already holds drip's hooks needs nothing, so it is fine.
        try write(AgentSetup.snippet(for: .claude), to: "dotfiles/settings.json")
        #expect(installer.install(.claude) == .done(lines: ["drip's hooks are already in ~/.claude/settings.json."], warnings: []))
    }

    @Test func aReadOnlyFileIsLeftAlone() throws {
        try write("{}", to: ".gemini/settings.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: "\(home)/.gemini/settings.json")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: "\(home)/.gemini/settings.json") }
        // root may write anything, so the check means nothing there.
        guard !FileManager.default.isWritableFile(atPath: "\(home)/.gemini/settings.json") else { return }
        guard case let .refused(reason, _) = installer.install(.gemini) else { Issue.record(); return }
        #expect(reason.hasPrefix("~/.gemini/settings.json is read-only, so drip leaves it alone"))
        #expect(file(".gemini/settings.json") == "{}")
    }

    @Test func codexMovesFromNotifyToHooks() throws {
        try write("model = \"gpt-5.5\"\nnotify = [\"drip\", \"hook\", \"codex\"]\n", to: ".codex/config.toml")
        #expect(installer.install(.codex) == .done(lines: [
            "Added drip's PermissionRequest and Stop hooks to ~/.codex/hooks.json.",
            "Removed notify from ~/.codex/config.toml: the Stop hook shows the done card instead.",
            "Backed up the old config.toml to ~/.codex/config.toml.drip-backup-20261021-171500.",
            "Codex runs a new hook only once you trust it: run /hooks in Codex.",
        ], warnings: []))
        #expect(file(".codex/config.toml") == "model = \"gpt-5.5\"\n")
        #expect(file(".codex/hooks.json") == AgentSetup.snippet(for: .codex))
    }

    @Test func codexNotifyInASymlinkedConfigStopsEverything() throws {
        try write("notify = [\"drip\", \"hook\", \"codex\"]\n", to: "dotfiles/config.toml")
        try FileManager.default.createDirectory(atPath: "\(home)/.codex", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: "\(home)/.codex/config.toml", withDestinationPath: "\(home)/dotfiles/config.toml")
        guard case let .refused(reason, snippet) = installer.install(.codex) else { Issue.record(); return }
        #expect(reason.hasPrefix("~/.codex/config.toml is a symlink"))
        #expect(reason.contains("notify"))
        #expect(snippet == AgentSetup.snippet(for: .codex))
        // Neither file changed: hooks alone would show every done card twice.
        #expect(file(".codex/hooks.json") == nil)
        #expect(file("dotfiles/config.toml") == "notify = [\"drip\", \"hook\", \"codex\"]\n")
    }

    @Test func codexWarnsAboutANotifyItCannotChange() throws {
        try write(#"notify = ["sh", "-c", "drip hook codex \"$1\""]"# + "\n", to: ".codex/config.toml")
        guard case let .done(_, warnings) = installer.install(.codex) else { Issue.record(); return }
        #expect(warnings == [
            "the notify in ~/.codex/config.toml runs drip too: take drip out of it, or every done card shows twice",
        ])
        #expect(file(".codex/config.toml") == #"notify = ["sh", "-c", "drip hook codex \"$1\""]"# + "\n")
    }

    @Test func codexHooksInConfigTomlAreEnough() throws {
        let config = ["PermissionRequest", "Stop"].map {
            "[[hooks.\($0)]]\n[[hooks.\($0).hooks]]\ntype = \"command\"\ncommand = \"drip hook codex\"\n"
        }.joined()
        try write(config, to: ".codex/config.toml")
        #expect(installer.install(.codex) == .done(lines: ["drip's hooks are already in ~/.codex/config.toml."], warnings: []))
        #expect(file(".codex/hooks.json") == nil)
    }

    @Test func codexAddsOnlyTheHooksConfigTomlLacks() throws {
        let config = "notify = [\"drip\", \"hook\", \"codex\"]\n[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ncommand = \"drip hook codex\"\n"
        try write(config, to: ".codex/config.toml")
        #expect(installer.install(.codex) == .done(lines: [
            "Added drip's PermissionRequest hook to ~/.codex/hooks.json.",
            "Removed notify from ~/.codex/config.toml: the Stop hook shows the done card instead.",
            "Backed up the old config.toml to ~/.codex/config.toml.drip-backup-20261021-171500.",
            "Codex runs a new hook only once you trust it: run /hooks in Codex.",
        ], warnings: []))
        let hooks = try JSONValue(parsing: file(".codex/hooks.json") ?? "")
        #expect(hooks["hooks"]?.members?.map(\.key) == ["PermissionRequest"])

        // Again: each event runs drip once, from one of the two files.
        #expect(installer.install(.codex) == .done(lines: [
            "drip's hooks are already in ~/.codex/config.toml and ~/.codex/hooks.json.",
        ], warnings: []))
    }

    @Test func codexWarnsAboutAnEventThatRunsDripInBothFiles() throws {
        try write("[hooks]\nStop = [{ hooks = [{ command = \"drip hook codex\" }] }]\n", to: ".codex/config.toml")
        try write(AgentSetup.snippet(for: .codex), to: ".codex/hooks.json")
        #expect(installer.install(.codex) == .done(lines: [
            "drip's hooks are already in ~/.codex/config.toml and ~/.codex/hooks.json.",
        ], warnings: [
            "~/.codex/config.toml and ~/.codex/hooks.json both run drip on Stop: take it out of one, "
                + "or every Stop card shows twice",
        ]))
        #expect(file(".codex/hooks.json") == AgentSetup.snippet(for: .codex))
        #expect(try backups(in: ".codex").isEmpty)
    }

    @Test func codexNamesWhatChangedWhenALaterWriteFails() throws {
        try write("notify = [\"drip\", \"hook\", \"codex\"]\n", to: ".codex/config.toml")
        // A directory in the way of hooks.json's temporary file fails its write after config.toml's.
        let temporary = "\(home)/.codex/.hooks.json.drip-\(ProcessInfo.processInfo.processIdentifier)"
        try FileManager.default.createDirectory(atPath: temporary, withIntermediateDirectories: true)
        guard case let .failed(message) = installer.install(.codex) else { Issue.record(); return }
        #expect(message.hasPrefix("could not write ~/.codex/hooks.json: "))
        #expect(message.hasSuffix("; drip already changed ~/.codex/config.toml, backed up to "
            + "~/.codex/config.toml.drip-backup-20261021-171500"))
        // The notify is gone, so no done card shows twice.
        #expect(file(".codex/config.toml") == "")
    }

    @Test func notJSONIsLeftAlone() throws {
        try write("{\n  // mine\n}\n", to: ".gemini/settings.json")
        #expect(installer.install(.gemini) == .refused(
            reason: "~/.gemini/settings.json is not plain JSON (line 2: comments are not JSON), so drip leaves it alone: "
                + "add these hooks to it yourself.",
            snippet: AgentSetup.snippet(for: .gemini)))
        #expect(file(".gemini/settings.json") == "{\n  // mine\n}\n")
    }
}
#endif
