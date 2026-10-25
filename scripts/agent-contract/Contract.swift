// Checks drip's hooks against the coding agents as they are today, for scripts/agent-contract.sh, which
// installs the latest Claude Code, Codex and Gemini CLI, builds drip and this file, and runs it.
//
// Each agent gets one short interactive session in a terminal of its own (tmux), through the hooks
// `drip setup` writes, in a world of its own under ~/.cache/drip-agent-contract: drip's state, config
// and card queue, the agent's home and settings. It never touches the drip, the history or the agents
// in use. drip is paused there, so the cards go to its history and never to the notch, and the check
// runs on a locked Mac too. A recorder stands in for `drip` on the hooks' PATH: it keeps each payload
// and hands it to the real drip.
//
// The session asks for a shell command the agent must ask to run, approves it through the terminal,
// then sends a second prompt while a card waits. It expects what a person would see: the waiting card
// appears, it goes once approved, a prompt takes a waiting card away, each turn ends with a done
// card, and a session never has two cards. The drift report then holds every payload up against what
// drip reads, as contract.json has it.
//
// Logins are never printed or written anywhere but where each agent keeps its own: Claude Code's
// long-lived token stays in the Keychain until the shell that starts the session reads it, Codex
// uses your own login through a link to it, and Gemini CLI has a Google sign-in of its own here.
import CoreGraphics
import Darwin
import Foundation

let fileManager = FileManager.default

func path(_ parts: String...) -> String {
    parts.joined(separator: "/")
}

func now() -> Double {
    Date().timeIntervalSince1970
}

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agent-contract: \(message)\n".utf8))
    exit(1)
}

/// A path in single quotes, for a shell script.
func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Text with anything that looks like a credential taken out, so no token reaches a log, a screen
/// capture or a saved payload.
func redacted(_ text: String) -> String {
    let patterns = [
        #"sk-ant-[A-Za-z0-9_-]{8,}"#, #"ya29\.[A-Za-z0-9._-]{8,}"#, #"1//[A-Za-z0-9_-]{20,}"#,
        #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+"#,
    ]
    return patterns.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]", options: .regularExpression) }
}

func firstLine(_ text: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty } ?? ""
    return String(redacted(line).prefix(200))
}

func pause(_ seconds: Double) {
    usleep(useconds_t(seconds * 1_000_000))
}

/// Polls `condition` until it holds or `seconds` pass. Returns whether it held.
@discardableResult
func waitFor(_ seconds: Double, every interval: Double = 0.25, _ condition: () -> Bool) -> Bool {
    let deadline = now() + seconds
    while true {
        if condition() { return true }
        if now() >= deadline { return false }
        pause(interval)
    }
}

// MARK: - Commands

struct Ran {
    var status: Int32
    var out: String
    var err: String
    var timedOut = false
}

/// Runs a command, its output kept, `input` on its standard input (nothing when nil), killed after
/// `timeout` seconds.
@discardableResult
func run(
    _ arguments: [String], environment: [String: String]? = nil, input: Data? = nil, in directory: String? = nil,
    timeout: Double = 120
) -> Ran {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    if let environment { process.environment = environment }
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
    let out = Pipe()
    let err = Pipe()
    let stdin = Pipe()
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    process.standardOutput = out
    process.standardError = err
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    let lock = NSLock()
    var outData = Data()
    var errData = Data()
    let readers = DispatchGroup()
    for (pipe, isOut) in [(out, true), (err, false)] {
        readers.enter()
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            if isOut { outData = data } else { errData = data }
            lock.unlock()
            readers.leave()
        }
    }
    do {
        try process.run()
    } catch {
        return Ran(status: 127, out: "", err: "\(arguments[0]): \(error.localizedDescription)")
    }
    if let input {
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
    }
    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        process.terminate()
        if exited.wait(timeout: .now() + 5) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
    }
    // A child the command left behind may hold its pipes open: what came so far is enough.
    _ = readers.wait(timeout: .now() + 5)
    lock.lock()
    defer { lock.unlock() }
    return Ran(
        status: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
        err: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
}

/// Runs a command that talks to you, in this terminal and in its process group, so it may read
/// from it. Returns its exit status; kills it after `timeout` seconds.
func runHere(_ arguments: [String], environment: [String: String], in directory: String, timeout: Double) -> Int32 {
    let argv = arguments.map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    // It starts where this process is, for the moment.
    let here = fileManager.currentDirectoryPath
    fileManager.changeCurrentDirectoryPath(directory)
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, arguments[0], nil, nil, argv, envp)
    fileManager.changeCurrentDirectoryPath(here)
    guard spawned == 0 else { return 127 }
    let deadline = now() + timeout
    var status: Int32 = 0
    while waitpid(pid, &status, WNOHANG) == 0 {
        if now() > deadline {
            kill(pid, SIGTERM)
            waitpid(pid, &status, 0)
            return 124
        }
        pause(0.2)
    }
    return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
}

// MARK: - JSON

func readJSON(_ file: String) -> Any? {
    fileManager.contents(atPath: file).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
}

func jsonText(_ value: Any, pretty: Bool = false) -> String {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
    if pretty { options.insert(.prettyPrinted) }
    return (try? JSONSerialization.data(withJSONObject: value, options: options)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
}

func write(_ text: String, to file: String, mode: Int = 0o644) {
    try? fileManager.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let temporary = file + ".tmp-\(getpid())"
    fileManager.createFile(atPath: temporary, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
    rename(temporary, file)
}

func typeName(_ value: Any) -> String {
    switch value {
    case is NSNull: return "null"
    case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
    case is String: return "string"
    case is [Any]: return "array"
    case is [String: Any]: return "object"
    default: return "unknown"
    }
}

// MARK: - The agents

enum Agent: String, CaseIterable {
    case claude, codex, gemini

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        }
    }

    var package: String {
        switch self {
        case .claude: return "@anthropic-ai/claude-code"
        case .codex: return "@openai/codex"
        case .gemini: return "@google/gemini-cli"
        }
    }

    /// What the agent's screen shows once it takes a prompt.
    var ready: [String] {
        switch self {
        case .claude, .codex: return ["? for shortcuts"]
        case .gemini: return ["Type your message"]
        }
    }

    /// What the agent's screen shows when it wants a login first.
    var wantsLogin: [String] {
        switch self {
        case .claude: return ["Select login method", "Please run /login", "Invalid API key", "OAuth token has expired"]
        case .codex: return ["Sign in with ChatGPT", "Provide your own API key"]
        case .gemini: return ["How would you like to authenticate", "Waiting for auth"]
        }
    }

    /// The first prompt: a shell command the agent has to ask to run.
    var firstPrompt: String {
        switch self {
        case .claude: return "Run the shell command `touch approved.txt` in this directory with your Bash tool, then reply with the single word done."
        case .codex: return "Run the shell command `touch approved.txt` in this directory. The sandbox is read-only, so ask for approval to run it outside the sandbox. Then reply with the single word done."
        case .gemini: return "Run the shell command `touch approved.txt` in this directory with your shell tool, then reply with the single word done."
        }
    }

    static let secondPrompt = "Reply with the single word ok."
}

/// What drip expects from one agent's hooks, from contract.json.
struct Contract {
    struct Shape {
        var reads: [String: String]
        var seen: Set<String>
    }

    var events: [String: Shape]
    var prompt: String
    var permission: String
    /// The notification_type of the permission event, when its event carries others too.
    var permissionType: String?
    var tool: String
    var done: String
    var same: [String]

    static func load(_ file: String, agent: Agent) -> Contract {
        guard let root = readJSON(file) as? [String: Any], let agents = root["agents"] as? [String: Any],
              let entry = agents[agent.rawValue] as? [String: Any], let events = entry["events"] as? [String: Any],
              let flow = entry["flow"] as? [String: String]
        else { fail("\(file) has no contract for \(agent.rawValue)") }
        var shapes: [String: Shape] = [:]
        for (event, value) in events {
            let shape = value as? [String: Any] ?? [:]
            shapes[event] = Shape(
                reads: shape["reads"] as? [String: String] ?? [:], seen: Set(shape["seen"] as? [String] ?? []))
        }
        return Contract(
            events: shapes, prompt: flow["prompt"] ?? "", permission: flow["permission"] ?? "",
            permissionType: flow["permissionType"], tool: flow["tool"] ?? "", done: flow["done"] ?? "",
            same: entry["same"] as? [String] ?? [])
    }

    func isPermission(_ payload: [String: Any]) -> Bool {
        payload["hook_event_name"] as? String == permission
            && (permissionType == nil || payload["notification_type"] as? String == permissionType)
    }
}

// MARK: - Options

struct Options {
    var mode = ""
    var repo = ""
    var cache = ""
    var tools = ""
    var tmux = ""
    var nodeBin = ""
    var agents = Agent.allCases
    var keep = false
    var drift: String?
    /// Whether there is a GUI session to show cards in; nil asks macOS, as drip does.
    var guiSession: Bool?
    /// The Keychain item that holds Claude Code's token: this service, account `claude`.
    var service = "drip-agent-contract"
    var codexAuth = (NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()) + "/.codex/auth.json"

    var contractFile: String { path(repo, "scripts/agent-contract/contract.json") }
    var geminiHome: String { path(cache, "gemini") }
    var setupHint: String { "scripts/agent-contract.sh --setup" }

    func tool(_ agent: Agent) -> String {
        path(tools, agent.rawValue)
    }

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var arguments = arguments[...]
        options.mode = arguments.popFirst() ?? ""
        func value(_ flag: String) -> String {
            guard let value = arguments.popFirst() else { fail("\(flag) needs a value") }
            return value
        }
        while let argument = arguments.popFirst() {
            switch argument {
            case "--repo": options.repo = value(argument)
            case "--cache": options.cache = value(argument)
            case "--tools": options.tools = value(argument)
            case "--tmux": options.tmux = value(argument)
            case "--node-bin": options.nodeBin = value(argument)
            case "--keychain-service": options.service = value(argument)
            case "--codex-auth": options.codexAuth = value(argument)
            case "--keep": options.keep = true
            case "--gui-session":
                switch value(argument) {
                case "yes": options.guiSession = true
                case "no": options.guiSession = false
                case let other: fail("--gui-session takes yes or no, not '\(other)'")
                }
            case "--drift": options.drift = value(argument)
            case "--only":
                options.agents = value(argument).split(separator: ",").map { name in
                    guard let agent = Agent(rawValue: String(name)) else {
                        fail("--only takes claude, codex and gemini, not '\(name)'")
                    }
                    return agent
                }
            default: fail("unknown option \(argument)")
            }
        }
        guard options.service.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            fail("--keychain-service takes letters, digits, dots, dashes and underscores")
        }
        return options
    }
}

// MARK: - A world of its own

/// One agent's scratch world: its home, drip's state, config and queue, the agent's settings, the
/// project the session runs in, and the recorder that stands in for drip.
struct World {
    let agent: Agent
    let root: String
    let options: Options

    var home: String { path(root, "home") }
    var state: String { path(root, "state") }
    var bin: String { path(root, "bin") }
    var drip: String { path(bin, "drip-real") }
    var capture: String { path(root, "capture") }
    /// Named for what the cards say: "drip-contract needs you".
    var project: String { path(root, "drip-contract") }
    var tmp: String { path(root, "tmp") }
    var socket: String { path(options.cache, "tmux-\(agent.rawValue).sock") }

    /// Where the agent keeps its settings: CLAUDE_CONFIG_DIR, CODEX_HOME, or GEMINI_CLI_HOME, whose
    /// `.gemini` holds them.
    var agentHome: String { path(root, agent.rawValue) }

    var environment: [String: String] {
        var environment = [
            "HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "SHELL": "/bin/zsh",
            "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "TMPDIR": tmp,
            "PATH": [bin, options.tools, options.nodeBin, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
            "XDG_STATE_HOME": state, "XDG_CONFIG_HOME": path(root, "config"), "XDG_CACHE_HOME": path(root, "cache"),
            "XDG_DATA_HOME": path(root, "data"), "DRIP_QUEUE_DIR": path(root, "queue"),
            // An agent's done card while you watch its terminal: shown all the same, so the check
            // never depends on which app is in front.
            "DRIP_WHEN_FOCUSED": "show",
            // No agent opens a browser here: a login it wants is a skip, never a sign-in.
            "BROWSER": "/usr/bin/false", "NO_BROWSER": "true",
            "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_TMPDIR": tmp,
        ]
        switch agent {
        case .claude: environment["CLAUDE_CONFIG_DIR"] = agentHome
        case .codex: environment["CODEX_HOME"] = agentHome
        case .gemini:
            environment["GEMINI_CLI_HOME"] = agentHome
            environment["GEMINI_CLI_TRUSTED_FOLDERS_PATH"] = path(root, "trustedFolders.json")
        }
        return environment
    }

    /// drip's environment with the agent's home as HOME, for `drip setup`: Gemini CLI's settings are
    /// in `~/.gemini`.
    var setupEnvironment: [String: String] {
        var environment = environment
        if agent == .gemini { environment["HOME"] = agentHome }
        return environment
    }

    /// Makes the world, with everything but drip's hooks, which `installHooks` adds once the login
    /// is known to work.
    func make(harness: String) {
        for directory in [home, state, bin, capture, project, tmp, agentHome] {
            try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        // A copy, so its processes are this world's own to find and stop.
        try? fileManager.copyItem(atPath: path(options.repo, ".build/release/drip"), toPath: drip)
        write("#!/bin/sh\nexec \(quoted(harness)) record \(quoted(capture)) \(quoted(drip)) \"$@\"\n", to: path(bin, "drip"), mode: 0o755)
        // Codex runs hooks through your shell, which sets PATH afresh: drip is on it, as it is once
        // installed.
        let profile = "export PATH=\(quoted(bin)):\"$PATH\"\n"
        for name in [".zshenv", ".profile", ".bashrc"] { write(profile, to: path(home, name)) }
        _ = run(["/usr/bin/git", "init", "-q", project], environment: environment)
        // Every card goes to the history, not to the notch.
        _ = run([drip, "pause", "1d"], environment: environment)

        switch agent {
        case .claude:
            let projects: [String: Any] = [project: ["hasTrustDialogAccepted": true, "hasCompletedProjectOnboarding": true]]
            let state: [String: Any] = ["hasCompletedOnboarding": true, "theme": "dark", "projects": projects]
            write(jsonText(state, pretty: true) + "\n", to: path(agentHome, ".claude.json"))
        case .codex:
            write("""
                approval_policy = "on-request"
                sandbox_mode = "read-only"
                check_for_update_on_startup = false

                [projects.\(jsonText(project))]
                trust_level = "trusted"

                """, to: path(agentHome, "config.toml"))
            try? fileManager.createSymbolicLink(atPath: path(agentHome, "auth.json"), withDestinationPath: options.codexAuth)
        case .gemini:
            let settings: [String: Any] = [
                "security": ["auth": ["selectedType": "oauth-personal"]],
                "general": ["enableAutoUpdate": false, "enableAutoUpdateNotification": false],
            ]
            write(jsonText(settings, pretty: true) + "\n", to: path(agentHome, ".gemini/settings.json"))
            write(jsonText([project: "TRUST_FOLDER"], pretty: true) + "\n", to: path(root, "trustedFolders.json"))
            for name in ["oauth_creds.json", "google_accounts.json"] {
                let source = path(options.geminiHome, ".gemini", name)
                if fileManager.fileExists(atPath: source) {
                    try? fileManager.createSymbolicLink(atPath: path(agentHome, ".gemini", name), withDestinationPath: source)
                }
            }
        }
    }

    /// drip's hooks, as `drip setup` adds them. Nil when they went in, else what went wrong.
    func installHooks() -> String? {
        let ran = run([drip, "setup", agent.rawValue], environment: setupEnvironment)
        return ran.status == 0 ? nil : firstLine(ran.err + ran.out)
    }

    /// Stops what the world started: its terminal, and any drip still holding cards.
    func stop() {
        _ = run([options.tmux, "-S", socket, "kill-server"], timeout: 10)
        _ = run(["/usr/bin/pkill", "-f", drip], timeout: 10)
        unlink(socket)
    }
}

// MARK: - Logins

enum Login {
    case ready
    case needsLogin(reason: String, fix: String)
    case failed(String)
}

/// Your own home, whatever HOME says: the Keychain is found from it.
let realHome = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()

/// Shell that reads Claude Code's token from the Keychain into the environment of the shell that
/// starts the agent: the token is never on a command line, in a file or in this process.
func readClaudeToken(_ options: Options) -> String {
    "CLAUDE_CODE_OAUTH_TOKEN=$(HOME=\(quoted(realHome)) /usr/bin/security find-generic-password -s \(quoted(options.service)) -a claude -w 2>/dev/null)"
}

func hasClaudeToken(_ options: Options) -> Bool {
    run(["/usr/bin/security", "find-generic-password", "-s", options.service, "-a", "claude"], timeout: 30).status == 0
}

/// Whether the agent's login works, from one tiny session that runs no hooks, before anything else.
/// No agent asks for a login or opens a browser here.
func checkLogin(_ world: World) -> Login {
    let options = world.options
    let prompt = "Reply with the single word ok."
    let authWords = #"(?i)(401|403|authenticat|oauth|/login|log ?in|sign ?in|credential|api key|token)"#
    switch world.agent {
    case .claude:
        guard hasClaudeToken(options) else {
            return .needsLogin(reason: "no Claude Code token in the Keychain", fix: "run \(options.setupHint)")
        }
        let script = "\(readClaudeToken(options)) || exit 97\nexport CLAUDE_CODE_OAUTH_TOKEN\nexec \"$@\""
        let ran = run(
            ["/bin/sh", "-c", script, "sh", options.tool(.claude), "-p", prompt],
            environment: world.environment, in: world.project, timeout: 180)
        if ran.status == 0 { return .ready }
        if ran.status == 97 {
            return .needsLogin(reason: "the Keychain would not give up the Claude Code token (is it locked?)", fix: "unlock the Keychain, or run \(options.setupHint)")
        }
        if (ran.out + ran.err).range(of: authWords, options: .regularExpression) != nil {
            return .needsLogin(reason: "Claude Code turned the saved token down: \(firstLine(ran.out + ran.err))", fix: "run \(options.setupHint)")
        }
        return .failed("claude -p exited \(ran.status)\(ran.timedOut ? " (timed out)" : ""): \(firstLine(ran.out + ran.err))")
    case .codex:
        guard fileManager.fileExists(atPath: options.codexAuth) else {
            return .needsLogin(reason: "no Codex login in ~/.codex", fix: "run codex login")
        }
        // Its output may name the account: only the status counts.
        let ran = run([options.tool(.codex), "login", "status"], environment: world.environment, timeout: 60)
        return ran.status == 0 ? .ready : .needsLogin(reason: "Codex says it is not logged in", fix: "run codex login")
    case .gemini:
        guard fileManager.fileExists(atPath: path(options.geminiHome, ".gemini/oauth_creds.json")) else {
            return .needsLogin(reason: "no Google sign-in for Gemini CLI here", fix: "run \(options.setupHint)")
        }
        let ran = run(
            [options.tool(.gemini), "-p", prompt], environment: world.environment, input: Data(), in: world.project,
            timeout: 180)
        if ran.status == 0 { return .ready }
        if (ran.out + ran.err).range(of: authWords, options: .regularExpression) != nil {
            return .needsLogin(reason: "Gemini CLI's Google sign-in no longer works: \(firstLine(ran.err + ran.out))", fix: "run \(options.setupHint)")
        }
        return .failed("gemini -p exited \(ran.status)\(ran.timedOut ? " (timed out)" : ""): \(firstLine(ran.err + ran.out))")
    }
}

// MARK: - The recorder

/// `record <capture> <drip> <arguments>`: what the hooks run as `drip`. Keeps the payload and how drip
/// took it, and passes drip's output and exit status on.
func record(_ arguments: [String]) -> Never {
    guard arguments.count >= 2 else { fail("record needs a capture directory and drip") }
    let capture = arguments[0]
    let drip = arguments[1]
    let rest = Array(arguments.dropFirst(2))
    let payload = rest.first == "hook" ? FileHandle.standardInput.readDataToEndOfFile() : nil
    var stamp = timespec()
    clock_gettime(CLOCK_REALTIME, &stamp)
    let stem = path(capture, String(format: "%010ld%09ld-%d", stamp.tv_sec, stamp.tv_nsec, getpid()))
    if let payload {
        fileManager.createFile(atPath: stem + ".json", contents: payload)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: drip)
    process.arguments = rest
    let input = Pipe()
    let errors = Pipe()
    process.standardInput = payload == nil ? FileHandle.standardInput : input
    process.standardError = errors
    var errorData = Data()
    let reading = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        errorData = errors.fileHandleForReading.readDataToEndOfFile()
        reading.signal()
    }
    do {
        try process.run()
    } catch {
        fail("cannot run \(drip): \(error.localizedDescription)")
    }
    if let payload {
        try? input.fileHandleForWriting.write(contentsOf: payload)
        try? input.fileHandleForWriting.close()
    }
    process.waitUntilExit()
    reading.wait()
    FileHandle.standardError.write(errorData)
    if payload != nil {
        let environment = ProcessInfo.processInfo.environment
        let meta: [String: Any] = [
            "status": process.terminationStatus, "stderr": String(decoding: errorData, as: UTF8.self),
            "environment": environment.filter { ["CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_ENTRYPOINT", "DRIP_HOOK"].contains($0.key) },
        ]
        write(jsonText(meta) + "\n", to: stem + ".meta.json")
    }
    exit(process.terminationStatus)
}

/// A payload the recorder kept, with how drip took it.
struct Captured {
    var stem: String
    var raw: Data
    var payload: [String: Any]
    var status: Int32
    var stderr: String
    var environment: [String: String]

    var event: String { payload["hook_event_name"] as? String ?? "(no hook_event_name)" }
    var session: String? { payload["session_id"] as? String }
}

func captured(in directory: String) -> [Captured] {
    let names = ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".meta.json") }.sorted()
    return names.compactMap { name in
        let stem = path(directory, String(name.dropLast(".meta.json".count)))
        guard let meta = readJSON(stem + ".meta.json") as? [String: Any], let raw = fileManager.contents(atPath: stem + ".json")
        else { return nil }
        return Captured(
            stem: stem, raw: raw, payload: (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:],
            status: (meta["status"] as? NSNumber)?.int32Value ?? -1, stderr: meta["stderr"] as? String ?? "",
            environment: meta["environment"] as? [String: String] ?? [:])
    }
}

// MARK: - What drip did

/// A card in the world's history, as `drip history --json` lists it.
struct Shown {
    var kind: String
    var id: String?
}

func history(_ world: World) -> [Shown] {
    run([world.drip, "history", "--json"], environment: world.environment, timeout: 30).out
        .split(separator: "\n").compactMap { line in
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let card = entry["card"] as? [String: Any]
            else { return nil }
            return Shown(kind: card["kind"] as? String ?? "", id: card["id"] as? String)
        }
}

/// The JSON objects in one of drip's state directories, such as its waiting cards.
func stateFiles(_ world: World, _ directory: String, prefix: String) -> [[String: Any]] {
    let folder = path(world.state, "drip", directory)
    let names = ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
    return names.compactMap { readJSON(path(folder, $0)) as? [String: Any] }
}

/// Whether drip keeps a card waiting for the session `id`.
func waiting(_ world: World, _ id: String) -> Bool {
    stateFiles(world, "agents", prefix: "waiting-").contains { $0["id"] as? String == id }
}

/// Whether drip asked for the session's card to go at `since` or later.
func dismissed(_ world: World, _ id: String, since: Double) -> Bool {
    stateFiles(world, "dismiss", prefix: "id-").contains {
        $0["id"] as? String == id && (($0["time"] as? NSNumber)?.doubleValue ?? 0) >= since - 0.5
    }
}

// MARK: - The session

struct Check {
    var name: String
    var ok: Bool
    var detail: String

    var json: [String: Any] { ["name": name, "ok": ok, "detail": detail] }
}

/// One live session of an agent, driven through its terminal.
final class Session {
    let world: World
    let contract: Contract
    var checks: [Check] = []
    var sessionID: String?
    /// Waiting cards the check put there itself, by replaying a request.
    var replayed = 0
    var screens: [String] = []

    init(world: World, contract: Contract) {
        self.world = world
        self.contract = contract
    }

    var agent: Agent { world.agent }
    var id: String { "\(agent.rawValue):\(sessionID ?? "?")" }

    func tmux(_ arguments: [String]) -> Ran {
        run([world.options.tmux, "-S", world.socket] + arguments, environment: world.environment, timeout: 15)
    }

    func screen() -> String {
        redacted(tmux(["capture-pane", "-p", "-t", "agent"]).out)
    }

    func keepScreen(_ why: String) {
        screens.append("\(why):\n" + screen().split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    func send(_ text: String) {
        _ = tmux(["send-keys", "-t", "agent", "-l", text])
        pause(0.5)
        press("Enter")
    }

    func press(_ key: String) {
        _ = tmux(["send-keys", "-t", "agent", key])
    }

    func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(Check(name: name, ok: ok, detail: detail))
        say("  \(ok ? "ok  " : "FAIL") \(name): \(detail)")
        if !ok { keepScreen(name) }
    }

    func payloads() -> [Captured] {
        captured(in: world.capture)
    }

    /// The first payload after `index` that `matches`, waiting up to `seconds` for it.
    func next(after index: Int, within seconds: Double, _ matches: (Captured) -> Bool) -> (Int, Captured)? {
        var found: (Int, Captured)?
        waitFor(seconds) {
            let all = payloads()
            found = all.indices.dropFirst(index + 1).first { matches(all[$0]) }.map { ($0, all[$0]) }
            return found != nil
        }
        return found
    }

    /// Starts the agent in its terminal: ready once it takes prompts.
    func start() -> Login {
        let tool = world.options.tool(agent)
        let command: String
        switch agent {
        case .claude:
            command = "\(readClaudeToken(world.options))\nexport CLAUDE_CODE_OAUTH_TOKEN\n\(quoted(tool))"
        case .codex:
            // Codex runs a new hook only once you trust it in /hooks; this session trusts drip's.
            command = "\(quoted(tool)) --no-daemon --dangerously-bypass-hook-trust"
        case .gemini:
            command = quoted(tool)
        }
        let launcher = path(world.root, "launch.sh")
        // The terminal stays once the agent exits, so its last words can be read.
        write("#!/bin/sh\n\(command)\necho \"[the agent exited $?]\"\nexec sleep 3600\n", to: launcher, mode: 0o755)
        let started = run(
            [world.options.tmux, "-S", world.socket, "-f", "/dev/null", "new-session", "-d", "-s", "agent", "-x", "200", "-y", "50",
             "-c", world.project, "/bin/sh \(quoted(launcher))"],
            environment: world.environment, timeout: 15)
        guard started.status == 0 else { return .failed("tmux would not start: \(firstLine(started.err))") }

        var shown = ""
        let up = waitFor(60, every: 0.5) {
            shown = screen()
            return agent.ready.contains { shown.contains($0) } || agent.wantsLogin.contains { shown.contains($0) }
        }
        if agent.wantsLogin.contains(where: { shown.contains($0) }) {
            keepScreen("the agent wants a login")
            return .needsLogin(reason: "\(agent.name) asked for a login when it started", fix: "run \(world.options.setupHint)")
        }
        // A prompt worded anew is no reason to stop: an agent with anything on screen gets the prompt.
        if !up, shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keepScreen("the agent did not come up")
            return .failed("\(agent.name) showed nothing within a minute")
        }
        // The prompt is drawn a moment before it takes keys.
        pause(2)
        return .ready
    }

    /// One turn: sends `prompt`, approves each permission the agent asks for, and checks the cards
    /// on the way. Returns the index of the payload that ended the turn, or nil when it never did.
    func turn(_ number: Int, _ prompt: String, after start: Int, clearsWaiting: Bool) -> Int? {
        let sentAt = now()
        send(prompt)
        var promptEvent = next(after: start, within: 15) { $0.event == self.contract.prompt }
        if promptEvent == nil {
            // An agent that took the text as a paste wants Enter once more.
            press("Enter")
            promptEvent = next(after: start, within: 30) { $0.event == self.contract.prompt }
        }
        guard let (promptIndex, promptPayload) = promptEvent else {
            check("turn \(number): the prompt reaches drip", false, "no \(contract.prompt) within 45 seconds of the prompt")
            return nil
        }
        if sessionID == nil { sessionID = promptPayload.session }
        check("turn \(number): the prompt reaches drip", promptPayload.session != nil,
              promptPayload.session != nil ? contract.prompt : "\(contract.prompt) has no session_id, so drip can tie no card to it")
        if clearsWaiting {
            let id = self.id
            let cleared = waitFor(15) { dismissed(world, id, since: sentAt) && !waiting(world, id) }
            check("turn \(number): a prompt takes the waiting card away", cleared,
                  cleared ? "\(contract.prompt) took it away" : "the card still waits after \(contract.prompt)")
        }

        var cursor = promptIndex
        var asked = false
        let deadline = now() + 300
        while now() < deadline {
            let all = payloads()
            guard let index = all.indices.dropFirst(cursor + 1).first(where: {
                contract.isPermission(all[$0].payload) || all[$0].event == contract.done || all[$0].event == "StopFailure"
            }) else {
                if number == 1, !asked, now() - sentAt > 150 {
                    check("turn 1: the agent asks before it runs the command", false,
                          "no \(contract.permission) reached drip within 150 seconds")
                    asked = true
                    // Approve whatever the agent shows, so the rest can still be checked.
                    press("Enter")
                }
                pause(0.25)
                continue
            }
            cursor = index
            if all[index].event == "StopFailure" {
                // Claude Code's turn died on an error, such as a login it no longer has.
                let error = all[index].payload["error"] as? String ?? "an error"
                check("turn \(number): the turn ends", false, "StopFailure: \(error): \(firstLine(all[index].payload["last_assistant_message"] as? String ?? ""))")
                return nil
            }
            if all[index].event == contract.done && !contract.isPermission(all[index].payload) {
                checkDone(number, index)
                return index
            }
            asked = true
            checkPermission(number, all[index])
        }
        check("turn \(number): the turn ends", false, "no \(contract.done) within 5 minutes")
        return nil
    }

    func checkPermission(_ number: Int, _ permission: Captured) {
        if sessionID == nil { sessionID = permission.session }
        let id = self.id
        let shows = waitFor(10) { waiting(world, id) && history(world).contains { $0.kind == "info" && $0.id == id } }
        check("turn \(number): the waiting card appears", shows,
              shows ? "\(contract.permission) shows an info card that waits" : explain(permission, wanted: "a waiting info card"))
        // Approve it, the way you would in the terminal: the first choice is yes, this once.
        pause(1)
        let approvedAt = now()
        press("Enter")
        let gone = waitFor(30) { dismissed(world, id, since: approvedAt) }
        let tool = payloads().contains { $0.event == contract.tool && $0.stem > permission.stem }
        let seconds = String(format: "%.1f", now() - approvedAt)
        check("turn \(number): the card goes once you approve", gone,
              gone ? "\(contract.tool) took it away \(seconds)s after the approval"
                  : tool ? "\(contract.tool) reached drip, but the card still waits 30 seconds after the approval"
                  : "no \(contract.tool) reached drip within 30 seconds of the approval")
    }

    func checkDone(_ number: Int, _ index: Int) {
        let id = self.id
        let done = waitFor(15) { history(world).filter { $0.kind == "ok" && $0.id == id }.count >= number }
        check("turn \(number): the done card shows", done,
              done ? "\(contract.done) shows an ok card" : explain(payloads()[index], wanted: "an ok card"))
    }

    /// Why a payload showed no card: how drip took it.
    func explain(_ payload: Captured, wanted: String) -> String {
        if payload.status != 0 || !payload.stderr.isEmpty {
            return "drip hook \(agent.rawValue) exited \(payload.status) on \(payload.event): \(firstLine(payload.stderr))"
        }
        if payload.environment["CLAUDE_CODE_SESSION_ATTENDED"] == "0" {
            return "the hook ran with CLAUDE_CODE_SESSION_ATTENDED=0, so drip took the session for one nobody attends"
        }
        let kinds = history(world).filter { $0.id == id }.map(\.kind)
        return "no \(wanted) in drip's history for \(id) after \(payload.event) (it has: \(kinds.isEmpty ? "nothing" : kinds.joined(separator: ", ")))"
    }

    /// The session from start to end, its checks in `checks`.
    func drive() {
        guard let first = turn(1, agent.firstPrompt, after: -1, clearsWaiting: false) else { return }
        // A card waits again, as when you would sooner type than approve: replays the request the
        // agent made, then sends a prompt.
        var clears = false
        if let permission = payloads().first(where: { contract.isPermission($0.payload) }) {
            _ = run([world.drip, "hook", agent.rawValue], environment: world.environment, input: permission.raw, timeout: 30)
            replayed += 1
            let id = self.id
            clears = waitFor(10) { waiting(world, id) }
            if !clears {
                check("turn 2: a card waits again", false, "replaying \(contract.permission) left no waiting card")
            }
        } else if !checks.contains(where: { $0.name.hasPrefix("turn 1: the agent asks") }) {
            check("turn 1: the agent asks before it runs the command", false, "the turn ended with no \(contract.permission)")
        }
        _ = turn(2, Agent.secondPrompt, after: first, clearsWaiting: clears)
    }

    /// Checks over the whole session, once it is over.
    func finish() {
        let all = payloads()
        let refused = all.filter { $0.status != 0 || !$0.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        check("drip takes every payload", refused.isEmpty,
              refused.isEmpty ? "\(all.count) hooks ran drip, each exited 0"
                  : refused.map { "\($0.event): exit \($0.status): \(firstLine($0.stderr))" }.joined(separator: "; "))

        let cards = history(world)
        let foreign = cards.filter { $0.id != id }
        let infos = cards.filter { $0.kind == "info" }.count
        let oks = cards.filter { $0.kind == "ok" }.count
        let others = cards.filter { $0.kind != "info" && $0.kind != "ok" }
        // Every Notification shows an info card, whatever it is about.
        let permissions = all.filter { $0.event == contract.permission || $0.event == "Notification" }.count + replayed
        let dones = all.filter { $0.event == contract.done }.count
        var problems: [String] = []
        if !foreign.isEmpty {
            problems.append("\(foreign.count) cards with another id than \(id) (\(foreign.map { $0.id ?? "none" }.joined(separator: ", ")))")
        }
        if infos != permissions { problems.append("\(infos) info cards for \(permissions) payloads that show one") }
        if oks != dones { problems.append("\(oks) ok cards for \(dones) \(contract.done) payloads") }
        if !others.isEmpty { problems.append("unexpected \(others.map(\.kind).joined(separator: ", ")) cards") }
        check("one card per session", problems.isEmpty,
              problems.isEmpty ? "\(cards.count) cards, each for \(id), one per event that shows one" : problems.joined(separator: "; "))

        if agent == .codex {
            let link = path(world.agentHome, "auth.json")
            let linked = (try? fileManager.destinationOfSymbolicLink(atPath: link)) == world.options.codexAuth
            check("your Codex login stays yours", linked,
                  linked ? "auth.json is still a link to ~/.codex/auth.json"
                      : "Codex replaced the link to your login with a file of its own: run codex login if Codex asks you to sign in again")
        }
    }
}

// MARK: - The drift report

struct Drift {
    var event: String
    var detail: String
    /// Whether drip shows the wrong cards for it, rather than only seeing something new.
    var breaking: Bool
    /// Whether it is an event the session never sent, which a model that went its own way can cause
    /// too, rather than a shape drip cannot read.
    var missing = false

    var json: [String: Any] { ["event": event, "detail": detail, "breaking": breaking] }
}

/// How the payloads differ from what drip reads. Fields only seen for the first time are not
/// breaking; a field drip reads that is missing or of another type, an event the session should have
/// sent and did not, and a permission request that does not match the tool call after it are.
func driftReport(_ payloads: [[String: Any]], contract: Contract) -> [Drift] {
    var found: [Drift] = []
    let events = payloads.compactMap { $0["hook_event_name"] as? String }
    for (role, event) in [("a prompt", contract.prompt), ("a permission request", contract.permission),
                          ("the tool call", contract.tool), ("the end of a turn", contract.done)]
    where !events.contains(event) {
        found.append(Drift(event: event, detail: "no \(event) payload, the hook drip runs on \(role)", breaking: true, missing: true))
    }
    if let type = contract.permissionType, events.contains(contract.permission), !payloads.contains(where: contract.isPermission) {
        let types = Set(payloads.filter { $0["hook_event_name"] as? String == contract.permission }
            .map { ($0["notification_type"] as? String) ?? "none" }).sorted()
        found.append(Drift(
            event: contract.permission,
            detail: "no \(contract.permission) has notification_type \(type), the only one drip keeps waiting (found: \(types.joined(separator: ", ")))",
            breaking: true))
    }

    var reported: Set<String> = []
    for payload in payloads {
        guard let event = payload["hook_event_name"] as? String else {
            found.append(Drift(event: "?", detail: "a payload with no hook_event_name: drip cannot read it", breaking: true))
            continue
        }
        guard let shape = contract.events[event] else {
            if reported.insert("event \(event)").inserted {
                found.append(Drift(event: event, detail: "drip has no hook for \(event)", breaking: true))
            }
            continue
        }
        for (field, type) in shape.reads.sorted(by: { $0.key < $1.key }) {
            let value = payload[field]
            let actual = value.map(typeName) ?? "missing"
            if actual != type, reported.insert("\(event).\(field)").inserted {
                found.append(Drift(
                    event: event,
                    detail: value == nil || value is NSNull ? "has no \(field), which drip reads" : "\(field) is a \(actual), drip reads a \(type)",
                    breaking: true))
            }
        }
        for field in payload.keys.sorted() where shape.reads[field] == nil && !shape.seen.contains(field) {
            if reported.insert("\(event).\(field)").inserted {
                found.append(Drift(event: event, detail: "a new field: \(field)", breaking: false))
            }
        }
    }

    // A permission request and the tool call after it must agree, or drip takes no card away.
    if !contract.same.isEmpty, let requested = payloads.firstIndex(where: contract.isPermission),
       let ran = payloads.indices.dropFirst(requested + 1).first(where: {
           payloads[$0]["hook_event_name"] as? String == contract.tool
               && payloads[$0]["tool_name"] as? String == payloads[requested]["tool_name"] as? String
       }) {
        let before = payloads[requested]
        let after = payloads[ran]
        for field in contract.same where jsonText(before[field] ?? NSNull()) != jsonText(after[field] ?? NSNull()) {
            var detail = "\(field) differs from \(contract.permission)'s, and drip matches the call by it"
            if let old = before[field] as? [String: Any], let new = after[field] as? [String: Any] {
                let gone = Set(old.keys).subtracting(new.keys).sorted()
                let added = Set(new.keys).subtracting(old.keys).sorted()
                let changed = Set(old.keys).intersection(new.keys).filter { jsonText(old[$0]!) != jsonText(new[$0]!) }.sorted()
                var parts: [String] = []
                if !gone.isEmpty { parts.append("\(contract.permission) has \(gone.joined(separator: ", ")), \(contract.tool) has not") }
                if !added.isEmpty { parts.append("\(contract.tool) adds \(added.joined(separator: ", "))") }
                if !changed.isEmpty { parts.append("\(changed.joined(separator: ", ")) changed") }
                detail += ": " + parts.joined(separator: "; ")
            } else if before[field] == nil || after[field] == nil {
                detail += ": \(before[field] == nil ? contract.permission : contract.tool) has none"
            }
            found.append(Drift(event: contract.tool, detail: detail, breaking: true))
        }
    }
    return found
}

/// The payloads to keep from a run, as `NN-<event>.json`, with your home named /home/user: they can
/// go into drip's tests as they are.
func keepPayloads(_ all: [Captured], in directory: String) {
    try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let home = NSHomeDirectory()
    for (index, payload) in all.enumerated() {
        let text = redacted(String(decoding: payload.raw, as: UTF8.self)).replacingOccurrences(of: home, with: "/home/user")
        write(text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", to: path(directory, String(format: "%02d-%@.json", index + 1, payload.event)))
    }
}

func savedPayloads(in directory: String) -> [[String: Any]] {
    let names = ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasSuffix(".meta.json") }.sorted()
    return names.compactMap { readJSON(path(directory, $0)) as? [String: Any] }
}

// MARK: - A run

struct AgentResult {
    var agent: Agent
    var version: String
    var status: String
    var reason: String?
    var fix: String?
    var checks: [Check] = []
    var drift: [Drift] = []
    var attempts = 1
    var payloads: String?
    var screens: [String] = []

    var json: [String: Any] {
        var json: [String: Any] = [
            "agent": agent.rawValue, "name": agent.name, "version": version, "status": status, "attempts": attempts,
            "checks": checks.map(\.json), "drift": drift.map(\.json),
        ]
        json["reason"] = reason
        json["fix"] = fix
        json["payloads"] = payloads
        return json
    }
}

func version(_ options: Options, _ agent: Agent, environment: [String: String]) -> String {
    let out = run([options.tool(agent), "--version"], environment: environment, timeout: 60).out
    return out.range(of: #"\d+\.\d+\.\d+[0-9A-Za-z.+-]*"#, options: .regularExpression).map { String(out[$0]) } ?? (firstLine(out).isEmpty ? "unknown" : firstLine(out))
}

/// One try at an agent, in a world of its own.
func attempt(_ agent: Agent, _ number: Int, options: Options, runDirectory: String, harness: String) -> AgentResult {
    let world = World(agent: agent, root: path(runDirectory, "world", "\(agent.rawValue)-\(number)"), options: options)
    world.make(harness: harness)
    defer {
        world.stop()
        if !options.keep { try? fileManager.removeItem(atPath: world.root) }
    }
    var result = AgentResult(agent: agent, version: version(options, agent, environment: world.environment), status: "failed", attempts: number)
    say("\(agent.name) \(result.version)\(number > 1 ? ", once more" : "")")

    func skip(_ login: Login, _ session: Session? = nil) -> AgentResult {
        switch login {
        case let .needsLogin(reason, fix):
            let reason = reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            result.status = "skipped"
            result.reason = "needs login: \(reason)"
            result.fix = fix
            say("  skipped, needs login: \(reason). Fix: \(fix)")
        case let .failed(reason):
            result.reason = reason
            say("  FAIL \(reason)")
        case .ready:
            break
        }
        result.screens = session?.screens ?? []
        return result
    }
    let login = checkLogin(world)
    guard case .ready = login else { return skip(login) }
    if let problem = world.installHooks() { return skip(.failed("drip setup \(agent.rawValue) failed: \(problem)")) }

    let contract = Contract.load(options.contractFile, agent: agent)
    let session = Session(world: world, contract: contract)
    let started = session.start()
    guard case .ready = started else { return skip(started, session) }
    session.drive()
    session.finish()

    let all = session.payloads()
    let kept = path(runDirectory, "payloads", agent.rawValue)
    keepPayloads(all, in: kept)
    result.payloads = kept
    result.drift = driftReport(savedPayloads(in: kept), contract: contract)
    for drift in result.drift {
        say("  \(drift.breaking ? "DRIFT" : "new  ") \(drift.event): \(drift.detail)")
    }
    // A Claude Code session that lost its login on the way still shows it in the end.
    if agent == .claude, all.contains(where: { $0.event == "StopFailure" && $0.payload["error"] as? String == "authentication_failed" }) {
        return skip(.needsLogin(reason: "Claude Code turned the saved token down", fix: "run \(options.setupHint)"), session)
    }
    result.checks = session.checks
    result.screens = session.screens
    result.status = session.checks.allSatisfy(\.ok) && !result.drift.contains(where: \.breaking) ? "passed" : "failed"
    return result
}

/// The exit status of a check that ran no agent, as there was no GUI session.
let noGUISessionStatus: Int32 = 3

/// drip shows and records no card without a GUI session, so every card check would fail: rather than
/// a false alarm, a check started outside the logged-in user's session runs no agent and says so in
/// last.json. Returns whether the check can go on.
func checkGUISession(_ options: Options) -> Bool {
    if options.guiSession ?? (CGSessionCopyCurrentDictionary() != nil) { return true }
    let reason = "no GUI session, so drip records no cards: run the check as a LaunchAgent in the logged-in user's session"
    let iso = ISO8601DateFormatter()
    let commit = run(["/usr/bin/git", "-C", options.repo, "rev-parse", "--short", "HEAD"], timeout: 15).out
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let stamp = iso.string(from: Date())
    let result: [String: Any] = [
        "version": 1, "status": "no-gui-session", "exit": noGUISessionStatus, "reason": reason, "started": stamp,
        "finished": stamp, "drip": commit, "agents": [Any](),
    ]
    write(jsonText(result, pretty: true) + "\n", to: path(options.cache, "last.json"))
    FileHandle.standardError.write(Data("agent-contract: \(reason)\n".utf8))
    return false
}

func runCheck(_ options: Options, harness: String) -> Int32 {
    guard checkGUISession(options) else { return noGUISessionStatus }
    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let started = Date()
    let runDirectory = path(options.cache, "runs", stamp.string(from: started))
    try? fileManager.createDirectory(atPath: runDirectory, withIntermediateDirectories: true)
    say("drip agent contract: \(runDirectory)")

    var results: [AgentResult] = []
    for agent in options.agents {
        var result = attempt(agent, 1, options: options, runDirectory: runDirectory, harness: harness)
        // A live session can go wrong once for reasons of its own; a shape drip cannot read never
        // comes right on a second try.
        if result.status == "failed", !result.drift.contains(where: { $0.breaking && !$0.missing }) {
            result = attempt(agent, 2, options: options, runDirectory: runDirectory, harness: harness)
        }
        results.append(result)
    }

    let failed = results.contains { $0.status == "failed" }
    let skipped = results.contains { $0.status == "skipped" }
    let exitStatus: Int32 = failed ? 1 : skipped ? 2 : 0
    let status = failed ? "failed" : skipped ? "needs-login" : "passed"
    let iso = ISO8601DateFormatter()
    let commit = run(["/usr/bin/git", "-C", options.repo, "rev-parse", "--short", "HEAD"], timeout: 15).out
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let summaryFile = path(runDirectory, "summary.txt")
    let result: [String: Any] = [
        "version": 1, "status": status, "exit": exitStatus, "started": iso.string(from: started),
        "finished": iso.string(from: Date()), "drip": commit, "run": runDirectory, "summary": summaryFile,
        "agents": results.map(\.json),
    ]
    let json = jsonText(result, pretty: true) + "\n"
    write(json, to: path(runDirectory, "last.json"))
    write(json, to: path(options.cache, "last.json"))
    let summary = summarize(results, status: status, exitStatus: exitStatus, started: started, runDirectory: runDirectory)
    write(summary, to: summaryFile)
    for result in results where !result.screens.isEmpty {
        write(result.screens.joined(separator: "\n\n") + "\n", to: path(runDirectory, "screens", "\(result.agent.rawValue).txt"))
    }
    if !options.keep { try? fileManager.removeItem(atPath: path(runDirectory, "world")) }
    say("")
    print(summary, terminator: "")
    prune(path(options.cache, "runs"), keeping: 12)
    return exitStatus
}

func summarize(_ results: [AgentResult], status: String, exitStatus: Int32, started: Date, runDirectory: String) -> String {
    let local = DateFormatter()
    local.dateFormat = "yyyy-MM-dd HH:mm"
    var lines = ["drip agent contract, \(local.string(from: started)): \(status) (exit \(exitStatus))"]
    for result in results {
        switch result.status {
        case "skipped":
            lines.append("\(result.agent.name) \(result.version): skipped, \(result.reason ?? "needs login"). Fix: \(result.fix ?? "")")
        default:
            let attempts = result.attempts > 1 ? ", on the second try" : ""
            lines.append("\(result.agent.name) \(result.version): \(result.status)\(attempts)\(result.reason.map { ", \($0)" } ?? "")")
            for check in result.checks where !check.ok {
                lines.append("  FAIL \(check.name): \(check.detail)")
            }
            for drift in result.drift where drift.breaking {
                lines.append("  DRIFT \(drift.event): \(drift.detail)")
            }
            let new = result.drift.filter { !$0.breaking }.count
            if new > 0 { lines.append("  \(new) new fields, which drip does not need: see last.json") }
        }
        if let payloads = result.payloads { lines.append("  payloads: \(payloads)") }
    }
    lines.append("Run: \(runDirectory)")
    return lines.joined(separator: "\n") + "\n"
}

/// Removes all but the newest `keeping` runs.
func prune(_ directory: String, keeping: Int) {
    let runs = ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    for name in runs.dropLast(keeping) {
        try? fileManager.removeItem(atPath: path(directory, name))
    }
}

/// `--drift DIR`: the drift report for payloads a run kept, in DIR or in its agents' folders in it.
func driftOnly(_ options: Options, directory: String) -> Int32 {
    let name = (directory as NSString).lastPathComponent
    var folders: [(Agent, String)] = []
    if let agent = Agent(rawValue: name) {
        folders = [(agent, directory)]
    } else if fileManager.fileExists(atPath: path(directory, "payloads")) {
        folders = Agent.allCases.map { ($0, path(directory, "payloads", $0.rawValue)) }
    } else {
        folders = Agent.allCases.map { ($0, path(directory, $0.rawValue)) }
    }
    folders = folders.filter { options.agents.contains($0.0) && fileManager.fileExists(atPath: $0.1) }
    if folders.isEmpty, options.agents.count == 1 { folders = [(options.agents[0], directory)] }
    guard !folders.isEmpty else {
        fail("\(directory) has no payloads: pass a run, its payloads folder, or one agent's, or name the agent with --only")
    }
    var breaking = false
    for (agent, folder) in folders {
        let payloads = savedPayloads(in: folder)
        let report = driftReport(payloads, contract: Contract.load(options.contractFile, agent: agent))
        say("\(agent.name): \(payloads.count) payloads, \(report.isEmpty ? "as drip expects" : "\(report.count) differences")")
        for drift in report {
            say("  \(drift.breaking ? "DRIFT" : "new  ") \(drift.event): \(drift.detail)")
        }
        breaking = breaking || report.contains(where: \.breaking)
    }
    return breaking ? 1 : 0
}

// MARK: - Setup

/// Passes a program's terminal output on with tokens blanked out, keeping the tokens.
struct Redactor {
    static let prefix = Array("sk-ant-".utf8)
    private(set) var tokens: [String] = []
    private var pending: [UInt8] = []

    static func inToken(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a) || byte == 0x2d || byte == 0x5f
    }

    /// What may be shown of the output so far. `final` once the output ends.
    mutating func feed(_ bytes: [UInt8], final: Bool = false) -> [UInt8] {
        pending += bytes
        var shown: [UInt8] = []
        while true {
            guard let start = Self.find(Self.prefix, in: pending) else {
                // Holds back an end that could be the start of a token.
                var hold = 0
                if !final {
                    for length in stride(from: min(Self.prefix.count - 1, pending.count), to: 0, by: -1)
                    where pending.suffix(length).elementsEqual(Self.prefix.prefix(length)) {
                        hold = length
                        break
                    }
                }
                shown += pending.dropLast(hold)
                pending = Array(pending.suffix(hold))
                return shown
            }
            shown += pending[..<start]
            var end = start + Self.prefix.count
            while end < pending.count, Self.inToken(pending[end]) { end += 1 }
            if end == pending.count, !final {
                pending = Array(pending[start...])
                return shown
            }
            let token = String(decoding: pending[start..<end], as: UTF8.self)
            if token.count >= 40 { tokens.append(token) }
            shown += Array("[the token, kept for the Keychain]".utf8)
            pending = Array(pending[end...])
        }
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        return (0...(haystack.count - needle.count)).first { haystack[$0..<($0 + needle.count)].elementsEqual(needle) }
    }
}

/// Runs a program in a terminal of its own, wide enough for a token on one line, and relays it to
/// this one with every token blanked out. Returns its exit status and the token it printed.
func relayRedacted(_ arguments: [String], environment: [String: String], in directory: String) -> (Int32, String?) {
    var size = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) != 0 || size.ws_row == 0 { size.ws_row = 40 }
    size.ws_col = max(size.ws_col, 220)
    let argv = arguments.map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    var master: Int32 = -1
    let pid = forkpty(&master, nil, nil, &size)
    if pid < 0 { return (127, nil) }
    if pid == 0 {
        chdir(directory)
        execve(arguments[0], argv, envp)
        _exit(127)
    }

    var original = termios()
    let terminal = isatty(STDIN_FILENO) == 1
    if terminal {
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }
    defer { if terminal { tcsetattr(STDIN_FILENO, TCSANOW, &original) } }

    var redactor = Redactor()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var reading = terminal
    var status: Int32 = 0
    var exited = false
    func show(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { _ = Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    }
    while true {
        var fds = [pollfd(fd: master, events: Int16(POLLIN), revents: 0), pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)]
        let ready = poll(&fds, reading ? 2 : 1, 200)
        if ready < 0 {
            if errno == EINTR { continue }
            break
        }
        if fds[0].revents != 0 {
            let count = read(master, &buffer, buffer.count)
            if count <= 0 { break }
            show(redactor.feed(Array(buffer[0..<count])))
            continue
        }
        if reading, fds[1].revents != 0 {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count <= 0 { reading = false } else { _ = buffer.withUnsafeBufferPointer { Darwin.write(master, $0.baseAddress, count) } }
        }
        // Something the program left behind may keep its terminal open: its own exit ends the relay.
        if ready == 0, waitpid(pid, &status, WNOHANG) == pid {
            exited = true
            break
        }
    }
    show(redactor.feed([], final: true))
    close(master)
    if !exited { waitpid(pid, &status, 0) }
    let exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    return (exitStatus, redactor.tokens.max { $0.count < $1.count })
}

/// A line read with the terminal's echo off; nil without a terminal.
func readHidden(_ prompt: String) -> String? {
    guard isatty(STDIN_FILENO) == 1 else { return nil }
    FileHandle.standardError.write(Data(prompt.utf8))
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var quiet = original
    quiet.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
    defer {
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        FileHandle.standardError.write(Data("\n".utf8))
    }
    return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Saves Claude Code's token in the Keychain, through `security`'s standard input so it is on no
/// command line. Returns whether the Keychain has it now.
func saveClaudeToken(_ token: String, _ options: Options) -> Bool {
    guard token.range(of: #"^[A-Za-z0-9._-]{20,}$"#, options: .regularExpression) != nil else { return false }
    let command = "add-generic-password -U -s \(options.service) -a claude -T /usr/bin/security -w \(token)\n"
    _ = run(["/usr/bin/security", "-i"], input: Data(command.utf8), timeout: 30)
    return hasClaudeToken(options)
}

/// `--setup`: the one-time sign-ins, each checked with a tiny session. Opens the browser only for
/// Claude Code's token and the Google sign-in, and only when they are not there or no longer work.
func setup(_ options: Options, harness: String) -> Int32 {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
        fail("--setup signs you in, so it needs a terminal: run it in one")
    }
    let scratch = path(options.cache, "setup")
    try? fileManager.removeItem(atPath: scratch)
    defer { try? fileManager.removeItem(atPath: scratch) }
    func world(_ agent: Agent) -> World {
        let world = World(agent: agent, root: path(scratch, agent.rawValue), options: options)
        world.make(harness: harness)
        return world
    }
    func describe(_ login: Login) -> String {
        switch login {
        case .ready: return "ready"
        case let .needsLogin(reason, fix): return "needs you: \(reason). Fix: \(fix)"
        case let .failed(reason): return "failed: \(reason)"
        }
    }
    var lines: [String] = []
    var ready = true

    for agent in options.agents {
        let world = world(agent)
        defer { world.stop() }
        var login = checkLogin(world)
        if case .ready = login {
            lines.append("\(agent.name): ready, the login there already works")
            continue
        }
        say("")
        switch agent {
        case .claude:
            say("Claude Code: a long-lived token for the check, from `claude setup-token`. Your browser opens to")
            say("approve it. The token goes straight into the Keychain: it is not shown, and no file keeps it.")
            var environment = world.environment
            environment.removeValue(forKey: "BROWSER")
            environment.removeValue(forKey: "NO_BROWSER")
            let (status, token) = relayRedacted([options.tool(.claude), "setup-token"], environment: environment, in: world.project)
            var chosen = token
            if chosen == nil, status == 0 {
                chosen = readHidden("No token showed up in setup-token's output. Paste the token it printed (it stays hidden): ")
            }
            if let chosen, !chosen.isEmpty {
                if saveClaudeToken(chosen, options) {
                    say("Saved the token in the Keychain (service \(options.service), account claude).")
                    login = checkLogin(world)
                } else {
                    login = .failed("the Keychain did not take the token")
                }
            } else {
                login = .needsLogin(reason: "claude setup-token gave no token (it exited \(status))", fix: "run \(options.setupHint) again")
            }
        case .codex:
            login = .needsLogin(reason: "this check uses your own Codex login, and Codex is not logged in", fix: "run codex login, then \(options.setupHint) again")
        case .gemini:
            say("Gemini CLI: one Google sign-in, kept in \(options.geminiHome) for the check only. Answer")
            say("its question with Enter, then sign in in the browser that opens.")
            let settings = path(options.geminiHome, ".gemini/settings.json")
            if !fileManager.fileExists(atPath: settings) {
                write(jsonText(["security": ["auth": ["selectedType": "oauth-personal"]]], pretty: true) + "\n", to: settings)
            }
            var environment = world.environment
            environment["GEMINI_CLI_HOME"] = options.geminiHome
            environment.removeValue(forKey: "BROWSER")
            environment.removeValue(forKey: "NO_BROWSER")
            let status = runHere([options.tool(.gemini), "-p", "Reply with the single word ok."], environment: environment,
                                 in: world.project, timeout: 600)
            // The sign-in is where the world links it from: a fresh world sees it.
            let fresh = World(agent: .gemini, root: path(scratch, "gemini-verify"), options: options)
            fresh.make(harness: harness)
            login = status == 0 ? checkLogin(fresh) : .needsLogin(reason: "the Google sign-in did not finish (gemini exited \(status))", fix: "run \(options.setupHint) again")
        }
        if case .ready = login {} else { ready = false }
        lines.append("\(agent.name): \(describe(login))")
    }

    say("")
    say("Setup:")
    for line in lines { say("  \(line)") }
    return ready ? 0 : 2
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "record" { record(Array(arguments.dropFirst())) }

let options = Options.parse(arguments)
guard let harness = Bundle.main.executablePath else { fail("cannot find this program's own path") }
if let directory = options.drift { exit(driftOnly(options, directory: directory)) }
// Before anything is installed: with no GUI session, no agent runs.
if options.mode == "session" {
    guard !options.repo.isEmpty, !options.cache.isEmpty else { fail("run this through scripts/agent-contract.sh") }
    exit(checkGUISession(options) ? 0 : noGUISessionStatus)
}
guard !options.repo.isEmpty, !options.cache.isEmpty, !options.tools.isEmpty, !options.tmux.isEmpty else {
    fail("run this through scripts/agent-contract.sh")
}

// One check at a time: a scheduled one and one by hand would share the terminals' names.
let lockFile = open(path(options.cache, "lock"), O_CREAT | O_RDWR, 0o600)
if lockFile < 0 || flock(lockFile, LOCK_EX | LOCK_NB) != 0 { fail("another check is running") }

// Ctrl-C or a stop from launchd still takes the agents and their terminals down.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGINT, SIGTERM, SIGHUP] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler {
        for agent in Agent.allCases {
            let socket = path(options.cache, "tmux-\(agent.rawValue).sock")
            _ = run([options.tmux, "-S", socket, "kill-server"], timeout: 5)
            unlink(socket)
        }
        _ = run(["/usr/bin/pkill", "-f", options.cache + "/.*/bin/drip-real"], timeout: 5)
        exit(1)
    }
    source.resume()
    signalSources.append(source)
}

switch options.mode {
case "setup": exit(setup(options, harness: harness))
case "run": exit(runCheck(options, harness: harness))
default: fail("unknown mode '\(options.mode)'")
}
