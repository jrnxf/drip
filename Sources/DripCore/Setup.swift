#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// `drip setup`: the hooks of a snippet file, in a coding agent's own settings. drip has no list of
/// events of its own: which events show a card is the snippet's choice, as a recipe makes it.
public enum AgentSetup {
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

    /// The hooks to put in a settings file, read from a snippet: `{ "hooks": { "<Event>": [ group ] } }`,
    /// where each group is as the agent's settings hold it and each of its handlers runs
    /// `drip hook <agent>`. Anything else is not drip's to install.
    public struct Snippet: Equatable {
        /// The groups for each event, in the snippet's order.
        public var events: [JSONMember]
        /// The agent the snippet is for.
        public var agent: AgentHook.Agent

        /// Reads a snippet. Throws a `UsageError` saying what is wrong with it.
        public init(parsing text: String, agent: AgentHook.Agent) throws {
            self.agent = agent
            let value: JSONValue
            do {
                value = try JSONValue(parsing: text)
            } catch let error as JSONError {
                throw UsageError("the snippet is not plain JSON (\(error))")
            }
            guard let members = value.members, members.allSatisfy({ $0.key == "hooks" }),
                  let hooks = members.last?.value.members
            else {
                throw UsageError("the snippet must be a JSON object with one \"hooks\" object, as the agent's settings hold hooks")
            }
            var events: [JSONMember] = []
            for event in hooks {
                guard let groups = event.value.elements else {
                    throw UsageError("the snippet's \"\(event.key)\" must be a list of hook groups")
                }
                // An event with no groups has no drip hook to put there.
                guard !groups.isEmpty else { continue }
                for group in groups {
                    guard let handlers = group["hooks"]?.elements, !handlers.isEmpty else {
                        throw UsageError("each hook group in the snippet's \"\(event.key)\" needs a non-empty \"hooks\" list")
                    }
                    for handler in handlers {
                        guard let command = handler["command"]?.string, AgentSetup.runsDrip(command: command, agent: agent) else {
                            throw UsageError(
                                "the snippet's \"\(event.key)\" hook must run drip hook \(agent.rawValue), "
                                    + "which drip setup keeps up to date; add other hooks to the settings yourself")
                        }
                    }
                }
                events.append(event)
            }
            self.events = events
        }

        /// The snippet as text.
        public var text: String {
            JSONValue.object([JSONMember("hooks", .object(events))]).formatted() + "\n"
        }

        /// The snippet with its hooks changed to run `drip-remote-hook`, as they do on another
        /// machine, where there is no drip. Throws a `UsageError` for a command that does not say
        /// `drip hook <agent>` plainly.
        public func remote() throws -> Snippet {
            let local = "drip hook \(agent.rawValue)"
            func convert(_ value: JSONValue) throws -> JSONValue {
                switch value {
                case let .object(members):
                    return .object(try members.map { member in
                        guard member.key == "command", let command = member.value.string else {
                            return JSONMember(member.key, try convert(member.value))
                        }
                        guard let range = command.range(of: local) else {
                            throw UsageError("--remote needs each hook's command to say '\(local)', not '\(command)'")
                        }
                        return JSONMember(
                            member.key,
                            .string(command[..<range.lowerBound] + RemoteHook.command(for: agent) + command[range.upperBound...]))
                    })
                case let .array(elements): return .array(try elements.map(convert))
                default: return value
                }
            }
            var copy = self
            copy.events = try events.map { JSONMember($0.key, try convert($0.value)) }
            return copy
        }
    }

    /// What putting a snippet in a settings file changes.
    public struct Merge: Equatable {
        /// The whole new file.
        public var text: String
        /// The events whose drip hooks were added or replaced.
        public var installed: [String]
        /// The events drip's hooks were taken out of, because the snippet has none for them.
        public var removed: [String]

        public init(text: String, installed: [String], removed: [String] = []) {
            self.text = text
            self.installed = installed
            self.removed = removed
        }
    }

    /// Why setup leaves a settings file alone.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var description: String

        public init(description: String) {
            self.description = description
        }
    }

    /// `group` without its handlers that run drip, or nil when none is left.
    static func strippingDrip(_ group: JSONValue, agent: AgentHook.Agent) -> JSONValue? {
        guard runsDrip(group, agent: agent) else { return group }
        guard var members = group.members, let at = members.firstIndex(where: { $0.key == "hooks" }),
              let handlers = members[at].value.elements
        else { return nil }
        let kept = handlers.filter { handler in
            !(handler["command"]?.string.map { runsDrip(command: $0, agent: agent) } ?? false)
        }
        guard !kept.isEmpty else { return nil }
        members[at].value = .array(kept)
        return .object(members)
    }

    /// Puts a snippet's hooks in a settings file's text, or in an empty file when `text` is nil, keeping
    /// everything else in its order and its indent. The hooks in the file that run drip are replaced:
    /// in place for an event the snippet names, and taken out of every other. Nil when the file holds
    /// the snippet's hooks already.
    public static func merge(_ text: String?, snippet: Snippet) throws -> Merge? {
        let agent = snippet.agent
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

        var installed: [String] = []
        var removed: [String] = []
        let wanted = Set(snippet.events.map(\.key))
        // The events the snippet leaves out lose their drip hooks.
        for index in events.indices.reversed() where !wanted.contains(events[index].key) {
            guard let groups = events[index].value.elements else { continue }
            let kept = groups.compactMap { strippingDrip($0, agent: agent) }
            guard kept != groups else { continue }
            removed.insert(events[index].key, at: 0)
            if kept.isEmpty { events.remove(at: index) } else { events[index].value = .array(kept) }
        }
        for event in snippet.events {
            let index = events.lastIndex { $0.key == event.key }
            var groups: [JSONValue]
            switch index.map({ events[$0].value }) {
            case nil: groups = []
            case let .array(elements)?: groups = elements
            default: throw Refusal(description: "has a \"hooks\".\"\(event.key)\" that is not a list")
            }
            var result: [JSONValue] = []
            var placed = false
            for group in groups {
                guard runsDrip(group, agent: agent) else {
                    result.append(group)
                    continue
                }
                if !placed {
                    result += event.value.elements ?? []
                    placed = true
                }
                if let rest = strippingDrip(group, agent: agent) { result.append(rest) }
            }
            if !placed { result += event.value.elements ?? [] }
            guard result != groups || index == nil else { continue }
            installed.append(event.key)
            if let index { events[index].value = .array(result) } else { events.append(JSONMember(event.key, .array(result))) }
        }
        guard !installed.isEmpty || !removed.isEmpty else { return nil }

        if let index = root.lastIndex(where: { $0.key == "hooks" }) {
            if events.isEmpty { root.remove(at: index) } else { root[index].value = .object(events) }
        } else if !events.isEmpty {
            root.append(JSONMember("hooks", .object(events)))
        }
        let original = empty ? "" : text ?? ""
        let indent = JSONValue.indent(of: original)
        // A new file, or one that ended with a newline, ends with one.
        let newline = empty || original.hasSuffix("\n") ? "\n" : ""
        return Merge(text: JSONValue.object(root).formatted(indent: indent) + newline, installed: installed, removed: removed)
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

    /// Puts the snippet's hooks in the agent's settings file.
    public func install(_ snippet: AgentSetup.Snippet) -> Outcome {
        let agent = snippet.agent
        let path = AgentSetup.settingsPath(for: agent, environment: environment)
        let text = snippet.text
        func refused(_ path: String, _ problem: String, _ advice: String = "add these hooks to it yourself") -> Outcome {
            .refused(reason: "\(display(path)) \(problem), so drip leaves it alone: \(advice).", snippet: text)
        }

        var lines: [String] = []
        var warnings: [String] = []
        /// What to do next, after what changed.
        var hints: [String] = []
        var writes: [(path: String, text: String)] = []

        // Codex: the hooks may be in config.toml too, and a notify that runs drip must go.
        var config: (path: String, value: CodexConfig)?
        if agent == .codex {
            let configPath = AgentSetup.codexConfigPath(environment: environment)
            if let text = try? String(contentsOfFile: configPath, encoding: .utf8) {
                config = (configPath, CodexConfig(text))
            }
        }
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
            if let merge = try AgentSetup.merge(existing, snippet: snippet) {
                if let problem = problem(writing: path) {
                    return refused(path, problem, problem.hasPrefix("is a symlink")
                        ? "add these hooks where it comes from" : "add these hooks to it yourself")
                }
                writes.append((path, merge.text))
                if !merge.installed.isEmpty {
                    let noun = merge.installed.count == 1 ? "hook" : "hooks"
                    lines.append("Put drip's \(Self.list(merge.installed)) \(noun) in \(display(path)).")
                }
                if !merge.removed.isEmpty {
                    let noun = merge.removed.count == 1 ? "hook" : "hooks"
                    lines.append("Took drip's \(Self.list(merge.removed)) \(noun) out of \(display(path)).")
                }
                if agent == .codex, !merge.installed.isEmpty {
                    hints.append("Codex runs a new hook only once you trust it: run /hooks in Codex.")
                }
            } else {
                lines.append("drip's hooks in \(display(path)) are the snippet's already.")
            }
        } catch let refusal as AgentSetup.Refusal {
            return refused(path, refusal.description)
        } catch {
            return .failed("\(display(path)): \(error)")
        }

        if let config, !config.value.dripHookEvents.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for event in AgentSetup.dripEvents(in: text, agent: agent) where config.value.dripHookEvents.contains(event) {
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
            lines.append("Removed notify from \(display(config.path)): the hooks show the cards instead.")
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
        if agent == .claude, !snippet.events.isEmpty {
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
