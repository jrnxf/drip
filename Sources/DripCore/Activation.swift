/// Which app a click on a card brings forward.
///
/// macOS sets `__CFBundleIdentifier` in the environment of everything an app starts, so a drip run
/// from a terminal, or from an agent's hook inside one, knows the terminal it came from.
public enum CardActivation {
    /// The `--activate` value that turns it off.
    public static let none = "none"

    /// The environment variable macOS sets to the bundle identifier of the app that started drip.
    public static let senderVariable = "__CFBundleIdentifier"

    /// `--activate` when given (`none` for no app), else the app drip was run from.
    public static func target(flag: String?, sender: String?) -> String? {
        if let flag {
            return flag == none ? nil : flag
        }
        return sender
    }

    /// The app that started drip, when the environment names one with a valid bundle identifier.
    public static func sender(in environment: [String: String]) -> String? {
        guard let sender = environment[senderVariable], isBundleIdentifier(sender) else { return nil }
        return sender
    }

    /// Whether `text` looks like a bundle identifier: letters, digits, hyphens and dots, such as
    /// `com.apple.Terminal`, without empty components.
    public static func isBundleIdentifier(_ text: String) -> Bool {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        return text.count <= 255 && components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

/// The terminal pane drip runs in, when a multiplexer or terminal says which: a click on the card
/// selects it once the terminal is in front, so the click lands on the session, not just the app.
public struct TerminalPane: Equatable, Sendable, Codable {
    /// tmux's server socket, the first field of `TMUX`.
    public var tmuxSocket: String?
    /// tmux's pane id, such as `%3`, from `TMUX_PANE`.
    public var tmuxPane: String?
    /// WezTerm's pane id, from `WEZTERM_PANE`.
    public var weztermPane: String?

    public init(tmuxSocket: String? = nil, tmuxPane: String? = nil, weztermPane: String? = nil) {
        self.tmuxSocket = tmuxSocket
        self.tmuxPane = tmuxPane
        self.weztermPane = weztermPane
    }

    /// The pane the environment names; nil when it names none. tmux comes first: WezTerm's
    /// variable reaches a tmux running inside it, where the pane that matters is tmux's.
    public init?(environment: [String: String]) {
        func value(_ name: String) -> String? {
            environment[name].flatMap { $0.isEmpty ? nil : $0 }
        }
        if let pane = value("TMUX_PANE"), Self.isPaneID(pane, prefix: "%"),
           let socket = value("TMUX")?.split(separator: ",", maxSplits: 1).first.map(String.init),
           socket.hasPrefix("/")
        {
            self.init(tmuxSocket: socket, tmuxPane: pane)
        } else if let pane = value("WEZTERM_PANE"), Self.isPaneID(pane, prefix: "") {
            self.init(weztermPane: pane)
        } else {
            return nil
        }
    }

    /// A pane id: the prefix, then digits only, so it is never read as an option or a command.
    static func isPaneID(_ text: String, prefix: String) -> Bool {
        guard text.hasPrefix(prefix) else { return false }
        let digits = text.dropFirst(prefix.count)
        return !digits.isEmpty && digits.count <= 12 && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The commands that bring this pane forward in its terminal, each as the program and its
    /// arguments. tmux: show the pane's window in the client attached to the pane's session, then
    /// the pane. WezTerm: activate the pane.
    public var selectCommands: [[String]] {
        if let pane = tmuxPane, let socket = tmuxSocket {
            return [
                ["tmux", "-S", socket, "select-window", "-t", pane],
                ["tmux", "-S", socket, "select-pane", "-t", pane],
            ]
        }
        if let pane = weztermPane {
            return [["wezterm", "cli", "activate-pane", "--pane-id", pane]]
        }
        return []
    }
}

extension TerminalPane {
    /// A tmux client, as `tmuxClientFormat` lists it.
    public struct TmuxClient: Equatable, Sendable {
        public var pid: Int32
        public var name: String
        public var session: String
        /// When it was last used, in seconds since 1970.
        public var activity: Int

        public init(pid: Int32, name: String, session: String, activity: Int) {
            self.pid = pid
            self.name = name
            self.session = session
            self.activity = activity
        }
    }

    /// The `list-clients -F` format `clients(fromTmuxList:)` reads.
    public static let tmuxClientFormat = "#{client_pid}\t#{client_name}\t#{client_session}\t#{client_activity}"

    /// The `display-message -p` format `isShowing(tmuxDisplay:)` reads.
    public static let tmuxShowingFormat = "#{pane_active} #{window_active} #{session_attached}"

    /// The clients in tmux's `list-clients -F tmuxClientFormat` output; lines it cannot read are left out.
    public static func clients(fromTmuxList output: String) -> [TmuxClient] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let pid = Int32(fields[0]), !fields[1].isEmpty, let activity = Int(fields[3])
            else { return nil }
            return TmuxClient(pid: pid, name: fields[1], session: fields[2], activity: activity)
        }
    }

    /// The client that shows `session`: the one used last among those attached to it, else the one
    /// used last of all, which a click switches to the session. Nil without a client.
    public static func client(for session: String, among clients: [TmuxClient]) -> TmuxClient? {
        let newest = { (clients: [TmuxClient]) in clients.max { $0.activity < $1.activity } }
        return newest(clients.filter { $0.session == session }) ?? newest(clients)
    }

    /// Whether tmux's `display-message -p tmuxShowingFormat` output says the pane shows: the active
    /// pane of its session's active window, with a client attached. Nil when it cannot be read.
    public static func isShowing(tmuxDisplay output: String) -> Bool? {
        let fields = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        return fields[0] == 1 && fields[1] == 1 && fields[2] > 0
    }
}
