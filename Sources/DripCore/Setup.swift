#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// `drip setup`: drip's hooks, in a coding agent's own settings.
public enum AgentSetup {
    /// One of drip's hooks: the event it runs on, and the matcher that picks which of them.
    struct Hook: Equatable {
        var event: String
        var matcher: String?
    }

    /// drip's hooks for the agent, in the order setup adds them: those that show a card, then those
    /// that take a waiting card away once the agent moves on (`AgentHook.clearEvents`).
    static func hooks(for agent: AgentHook.Agent) -> [Hook] {
        let shows: [Hook]
        switch agent {
        case .claude:
            // PermissionRequest says what Claude wants to do, so the Notification hook is only for
            // questions. Not idle_prompt: it comes a minute after every finished turn, and its card
            // would replace the done card that says what Claude did.
            shows = [
                Hook(event: "PermissionRequest"),
                Hook(event: "Notification", matcher: "elicitation_dialog"),
                Hook(event: "Stop"),
                Hook(event: "StopFailure"),
            ]
        case .codex:
            shows = [Hook(event: "PermissionRequest"), Hook(event: "Stop")]
        case .gemini:
            shows = [Hook(event: "Notification"), Hook(event: "AfterAgent")]
        }
        return shows + AgentHook.clearEvents(for: agent).map { Hook(event: $0) }
    }

    /// Matchers drip's own hooks had before, which setup brings up to date: Claude's Notification
    /// hook also showed permission prompts before drip read PermissionRequest.
    static let oldMatchers: [String: Set<String>] = [
        "Notification": ["permission_prompt|elicitation_dialog", "permission_prompt|idle_prompt|elicitation_dialog"],
    ]

    /// The command each of drip's hooks runs.
    public static func command(for agent: AgentHook.Agent) -> String {
        "drip hook \(agent.rawValue)"
    }

    /// The settings file drip's hooks go in, from the environment: Claude Code's moves with
    /// `CLAUDE_CONFIG_DIR`, Codex's with `CODEX_HOME`.
    public static func settingsPath(for agent: AgentHook.Agent, environment: [String: String]) -> String {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "~"
        func directory(_ variable: String, _ fallback: String) -> String {
            environment[variable].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/\(fallback)"
        }
        switch agent {
        case .claude: return directory("CLAUDE_CONFIG_DIR", ".claude") + "/settings.json"
        case .codex: return directory("CODEX_HOME", ".codex") + "/hooks.json"
        case .gemini: return "\(home)/.gemini/settings.json"
        }
    }

    /// Codex's config.toml, next to its hooks.json.
    public static func codexConfigPath(environment: [String: String]) -> String {
        (settingsPath(for: .codex, environment: environment) as NSString).deletingLastPathComponent + "/config.toml"
    }

    /// One of drip's hook groups, as the settings file holds it.
    static func group(_ hook: Hook, agent: AgentHook.Agent) -> JSONValue {
        var handler = [JSONMember("type", .string("command")), JSONMember("command", .string(command(for: agent)))]
        if agent == .gemini {
            // Gemini CLI names a hook in its /hooks list, and enables and disables it by that name.
            handler.insert(JSONMember("name", .string("drip")), at: 0)
        }
        var members = [JSONMember("hooks", .array([.object(handler)]))]
        if let matcher = hook.matcher {
            members.insert(JSONMember("matcher", .string(matcher)), at: 0)
        }
        return .object(members)
    }

    /// drip's hooks as the settings file holds them, as `drip setup --print` shows them.
    public static func snippet(for agent: AgentHook.Agent) -> String {
        let events = hooks(for: agent).map { JSONMember($0.event, .array([group($0, agent: agent)])) }
        return JSONValue.object([JSONMember("hooks", .object(events))]).formatted() + "\n"
    }

    /// What adding drip's hooks changes in a settings file.
    public struct Merge: Equatable {
        /// The whole new file.
        public var text: String
        /// The events drip's hooks were added to.
        public var added: [String]
        /// The events whose drip hook's matcher was brought up to date.
        public var updated: [String] = []

        public init(text: String, added: [String], updated: [String] = []) {
            self.text = text
            self.added = added
            self.updated = updated
        }
    }

    /// Why setup leaves a settings file alone.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var description: String

        public init(description: String) {
            self.description = description
        }
    }

    /// Adds drip's hooks to a settings file's text, or to an empty file when `text` is nil, keeping
    /// everything else in its order and its indent, except those for `skipping`, events that run drip
    /// from somewhere else. Nil when drip's hooks are all there already.
    public static func merge(_ text: String?, agent: AgentHook.Agent, skipping: Set<String> = []) throws -> Merge? {
        let empty = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        var root: [JSONMember]
        if empty {
            root = []
        } else {
            let value: JSONValue
            do {
                value = try JSONValue(parsing: text ?? "")
            } catch let error as JSONError {
                throw Refusal(description: "is not plain JSON (\(error))")
            }
            guard let members = value.members else { throw Refusal(description: "is not a JSON object") }
            root = members
        }
        var events: [JSONMember]
        switch root.last(where: { $0.key == "hooks" })?.value {
        case nil: events = []
        case let .object(members)?: events = members
        default: throw Refusal(description: "has a \"hooks\" that is not an object")
        }

        var added: [String] = []
        var updated: [String] = []
        for hook in hooks(for: agent) where !skipping.contains(hook.event) {
            let index = events.lastIndex { $0.key == hook.event }
            let before = index.map { events[$0].value }
            var groups: [JSONValue]
            switch index.map({ events[$0].value }) {
            case nil: groups = []
            case let .array(elements)?: groups = elements
            default: throw Refusal(description: "has a \"hooks\".\"\(hook.event)\" that is not a list")
            }
            if let index = groups.firstIndex(where: { runsDrip($0, agent: agent) }) {
                // drip's own group with a matcher drip no longer uses: bring it up to date.
                guard let matcher = hook.matcher, var members = groups[index].members,
                      let at = members.firstIndex(where: { $0.key == "matcher" }),
                      let old = members[at].value.string, old != matcher,
                      oldMatchers[hook.event]?.contains(old) ?? false,
                      groups[index]["hooks"]?.elements?.count == 1
                else { continue }
                members[at].value = .string(matcher)
                groups[index] = .object(members)
                updated.append(hook.event)
            } else {
                groups.append(group(hook, agent: agent))
                added.append(hook.event)
            }
            if let index {
                if before != .array(groups) { events[index].value = .array(groups) }
            } else {
                events.append(JSONMember(hook.event, .array(groups)))
            }
        }
        guard !added.isEmpty || !updated.isEmpty else { return nil }

        if let index = root.lastIndex(where: { $0.key == "hooks" }) {
            root[index].value = .object(events)
        } else {
            root.append(JSONMember("hooks", .object(events)))
        }
        let original = empty ? "" : text ?? ""
        let indent = JSONValue.indent(of: original)
        // A new file, or one that ended with a newline, ends with one.
        let newline = empty || original.hasSuffix("\n") ? "\n" : ""
        return Merge(text: JSONValue.object(root).formatted(indent: indent) + newline, added: added, updated: updated)
    }

    /// The events, in order, whose hooks in a settings file's text run drip. None when it is not JSON.
    static func dripEvents(in text: String, agent: AgentHook.Agent) -> [String] {
        let events = (try? JSONValue(parsing: text))?["hooks"]?.members ?? []
        return events.filter { event in
            event.value.elements?.contains { group in runsDrip(group, agent: agent) } ?? false
        }.map(\.key)
    }

    /// Whether a hook group runs `drip hook <agent>`, as drip's own command or by a path to drip.
    static func runsDrip(_ group: JSONValue, agent: AgentHook.Agent) -> Bool {
        group["hooks"]?.elements?.contains { handler in
            handler["command"]?.string.map { runsDrip(command: $0, agent: agent) } ?? false
        } ?? false
    }

    /// Whether a command line runs `drip hook <agent>`, with drip named or given by its path.
    public static func runsDrip(command: String, agent: AgentHook.Agent) -> Bool {
        let quotes: Set<Character> = ["\"", "'"]
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map { word -> Substring in
            var word = word
            while let first = word.first, quotes.contains(first) { word = word.dropFirst() }
            while let last = word.last, quotes.contains(last) { word = word.dropLast() }
            return word
        }
        return words.indices.dropLast(2).contains { index in
            words[index].split(separator: "/").last == "drip" && words[index + 1] == "hook"
                && words[index + 2] == agent.rawValue
        }
    }
}

/// What drip reads in Codex's config.toml: whether its `notify` runs drip, which would show a second
/// done card next to the Stop hook's, and which events its hooks already run drip on.
public struct CodexConfig: Equatable {
    /// The lines of a top-level `notify` that runs only `drip hook codex`, which setup removes.
    public var dripNotify: Range<Int>?
    /// A top-level `notify` that runs drip some other way, which setup cannot remove for you.
    public var otherDripNotify = false
    /// The events whose hooks here run drip: `[[hooks.<Event>]]` tables, `<Event> = [...]` in a
    /// `[hooks]` table, or `hooks.<Event> = [...]`.
    public var dripHookEvents: Set<String> = []

    let lines: [Substring]

    public init(_ text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var table: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = Self.keys(line.drop(while: { $0 == "[" }).prefix(while: { $0 != "]" }))
                index += 1
                continue
            }
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else {
                index += 1
                continue
            }
            let path = table + Self.keys(line[..<equals])
            // The value runs on to the line that closes its brackets and its strings.
            var value = Value()
            value.read(line[line.index(after: equals)...])
            var end = index
            while !value.isComplete, end < lines.count - 1 {
                end += 1
                value.read(lines[end])
            }
            let words = value.strings
            if path == ["notify"] {
                if words.count == 3, words[0].split(separator: "/").last == "drip", words[1] == "hook",
                   words[2] == "codex" {
                    dripNotify = index..<(end + 1)
                } else if words.contains(where: { $0.contains("drip") }) {
                    otherDripNotify = true
                }
            } else if path.count >= 2, path[0] == "hooks",
                      words.contains(where: { AgentSetup.runsDrip(command: $0, agent: .codex) }) {
                dripHookEvents.insert(path[1])
            }
            index = end + 1
        }
    }

    /// The parts of a dotted TOML key or table name, without their quotes.
    static func keys(_ name: Substring) -> [String] {
        name.split(separator: ".").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")) }
    }

    /// The text without drip's `notify`.
    public var withoutDripNotify: String {
        guard let dripNotify else { return lines.joined(separator: "\n") }
        var lines = lines
        lines.removeSubrange(dripNotify)
        return lines.joined(separator: "\n")
    }

    /// A TOML value read line by line: its quoted strings, in order, and whether its brackets, braces
    /// and strings are all closed. Strings may be `"…"`, `'…'`, or `"""…"""` and `'''…'''` over several lines.
    struct Value {
        private(set) var strings: [String] = []
        private var depth = 0
        /// The delimiter of the string being read.
        private var quote: String?
        private var current = ""

        var isComplete: Bool { quote == nil && depth <= 0 }

        mutating func read(_ line: Substring) {
            let characters = Array(line)
            var index = 0
            var escaped = false
            func run(of character: Character) -> Int {
                characters[index...].prefix(while: { $0 == character }).count
            }
            while index < characters.count {
                let character = characters[index]
                if let open = quote {
                    let basic = open.first == "\""
                    if escaped {
                        current.append(character)
                        escaped = false
                        index += 1
                    } else if basic, character == "\\" {
                        escaped = true
                        index += 1
                    } else if open.count == 3, character == open.first, run(of: character) >= 3 {
                        // Up to two quotes before the closing three belong to the string.
                        let quotes = min(run(of: character), 5)
                        current += String(repeating: character, count: quotes - 3)
                        close()
                        index += quotes
                    } else if open.count == 1, character == open.first {
                        close()
                        index += 1
                    } else {
                        current.append(character)
                        index += 1
                    }
                } else if character == "\"" || character == "'" {
                    let length = run(of: character) >= 3 ? 3 : 1
                    quote = String(repeating: character, count: length)
                    index += length
                    // A multi-line string leaves out a newline right after its opening delimiter.
                    if length == 3, index == characters.count { return }
                } else if character == "#" {
                    return
                } else {
                    if character == "[" || character == "{" { depth += 1 }
                    if character == "]" || character == "}" { depth -= 1 }
                    index += 1
                }
            }
            if let open = quote {
                if open.count == 1 {
                    close()
                } else if !escaped {
                    current.append("\n")
                }
            }
        }

        private mutating func close() {
            strings.append(current)
            current = ""
            quote = nil
        }
    }
}

#if !os(WASI)
/// Adds drip's hooks to an agent's settings file on disk. A file that is a symlink or read-only, such
/// as one home-manager manages, is never written or replaced: drip says why and prints its hooks.
public struct SetupInstaller {
    public var environment: [String: String]
    /// When the backups are stamped.
    public var now: Date

    public init(environment: [String: String], now: Date = Date()) {
        self.environment = environment
        self.now = now
    }

    public enum Outcome: Equatable {
        /// The hooks are in place: what changed, for stdout, and anything to warn about.
        case done(lines: [String], warnings: [String])
        /// Nothing was changed: why, for stderr, and drip's hooks to add by hand, for stdout.
        case refused(reason: String, snippet: String)
        /// A write failed: what went wrong.
        case failed(String)
    }

    public func install(_ agent: AgentHook.Agent) -> Outcome {
        let path = AgentSetup.settingsPath(for: agent, environment: environment)
        let snippet = AgentSetup.snippet(for: agent)
        func refused(_ path: String, _ problem: String, _ advice: String = "add these hooks to it yourself") -> Outcome {
            .refused(reason: "\(display(path)) \(problem), so drip leaves it alone: \(advice).", snippet: snippet)
        }

        var lines: [String] = []
        var warnings: [String] = []
        /// What to do next, after what changed.
        var hints: [String] = []
        var writes: [(path: String, text: String)] = []

        // Codex: the hooks may be in config.toml already, and a notify that runs drip must go.
        var config: (path: String, value: CodexConfig)?
        if agent == .codex {
            let configPath = AgentSetup.codexConfigPath(environment: environment)
            if let text = try? String(contentsOfFile: configPath, encoding: .utf8) {
                config = (configPath, CodexConfig(text))
            }
        }
        let inConfig = config?.value.dripHookEvents ?? []
        if let config, AgentSetup.hooks(for: agent).allSatisfy({ inConfig.contains($0.event) }) {
            lines.append("drip's hooks are already in \(display(config.path)).")
        } else {
            let existing: String?
            if FileManager.default.fileExists(atPath: path) {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return refused(path, "cannot be read as text")
                }
                existing = text
            } else {
                existing = nil
            }
            do {
                if let merge = try AgentSetup.merge(existing, agent: agent, skipping: inConfig) {
                    if let problem = problem(writing: path) {
                        return refused(path, problem, problem.hasPrefix("is a symlink")
                            ? "add these hooks where it comes from" : "add these hooks to it yourself")
                    }
                    writes.append((path, merge.text))
                    if !merge.added.isEmpty {
                        let noun = merge.added.count == 1 ? "hook" : "hooks"
                        lines.append("Added drip's \(Self.list(merge.added)) \(noun) to \(display(path)).")
                    }
                    if !merge.updated.isEmpty {
                        let noun = merge.updated.count == 1 ? "hook's matcher" : "hooks' matchers"
                        lines.append("Brought drip's \(Self.list(merge.updated)) \(noun) up to date in \(display(path)).")
                    }
                    if agent == .codex, !merge.added.isEmpty {
                        hints.append("Codex runs a new hook only once you trust it: run /hooks in Codex.")
                    }
                } else if let config, !inConfig.isEmpty {
                    lines.append("drip's hooks are already in \(display(config.path)) and \(display(path)).")
                } else {
                    lines.append("drip's hooks are already in \(display(path)).")
                }
            } catch let refusal as AgentSetup.Refusal {
                return refused(path, refusal.description)
            } catch {
                return .failed("\(display(path)): \(error)")
            }
        }

        if let config, !inConfig.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for event in AgentSetup.dripEvents(in: text, agent: agent) where inConfig.contains(event) {
                warnings.append(
                    "\(display(config.path)) and \(display(path)) both run drip on \(event): take it out of one, "
                        + "or every \(event) card shows twice")
            }
        }

        if let config, config.value.dripNotify != nil {
            if let problem = problem(writing: config.path) {
                return refused(
                    config.path, problem,
                    "take out its notify, which also runs drip and would show every done card twice, then add these hooks")
            }
            writes.insert((config.path, config.value.withoutDripNotify), at: 0)
            lines.append("Removed notify from \(display(config.path)): the Stop hook shows the done card instead.")
        } else if let config, config.value.otherDripNotify {
            warnings.append(
                "the notify in \(display(config.path)) runs drip too: take drip out of it, or every done card shows twice")
        }

        /// The files written so far, with their backups.
        var written: [String] = []
        for write in writes {
            do {
                if let backup = try self.write(write.text, to: write.path) {
                    lines.append("Backed up the old \((write.path as NSString).lastPathComponent) to \(display(backup)).")
                    written.append("\(display(write.path)), backed up to \(display(backup))")
                } else {
                    written.append(display(write.path))
                }
            } catch {
                let changed = written.isEmpty ? "" : "; drip already changed \(written.joined(separator: " and "))"
                return .failed("could not write \(display(write.path)): \(error.localizedDescription)\(changed)")
            }
        }
        if agent == .claude {
            hints.append(
                "Claude Code can also notify you itself, through your terminal: if each card comes with a "
                    + "second notification, set Local notifications to disabled in its /config.")
        }
        return .done(lines: lines + hints, warnings: warnings)
    }

    /// Why drip may not change the file at `path`, or nil when it may. A symlink belongs to whatever
    /// made it, and replacing it would cut the file off from it.
    func problem(writing path: String) -> String? {
        let manager = FileManager.default
        if (try? manager.destinationOfSymbolicLink(atPath: path)) != nil {
            return "is a symlink, as home-manager and other dotfile managers make"
        }
        if manager.fileExists(atPath: path), !manager.isWritableFile(atPath: path) {
            return "is read-only"
        }
        let directory = (path as NSString).deletingLastPathComponent
        if manager.fileExists(atPath: directory), !manager.isWritableFile(atPath: directory) {
            return "is in a read-only directory"
        }
        return nil
    }

    /// Writes the file whole, through a temporary file renamed over it, keeping its permissions, after
    /// copying the old one to a timestamped backup next to it. Returns the backup's path.
    func write(_ text: String, to path: String) throws -> String? {
        let manager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var permissions = 0o644
        var backup: String?
        if manager.fileExists(atPath: path) {
            permissions = (try manager.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? permissions
            let copy = backupPath(for: path)
            try manager.copyItem(atPath: path, toPath: copy)
            backup = copy
        }
        let name = (path as NSString).lastPathComponent
        let temporary = "\(directory)/.\(name).drip-\(ProcessInfo.processInfo.processIdentifier)"
        guard manager.createFile(
            atPath: temporary, contents: Data(text.utf8), attributes: [.posixPermissions: permissions])
        else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary])
        }
        guard rename(temporary, path) == 0 else {
            let code = errno
            try? manager.removeItem(atPath: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return backup
    }

    /// `<path>.drip-backup-<local time>`, such as `settings.json.drip-backup-20261021-171500`, numbered
    /// when a backup from the same second is there.
    func backupPath(for path: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(path).drip-backup-\(formatter.string(from: now))"
        var candidate = base
        var number = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        return candidate
    }

    /// A path with the home directory as `~`.
    func display(_ path: String) -> String {
        guard let home = environment["HOME"], !home.isEmpty, home != "/", path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// `A`, `A and B`, `A, B and C`.
    static func list(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}
#endif
