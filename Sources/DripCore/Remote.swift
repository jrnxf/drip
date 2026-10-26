#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// Agents on another machine, which has no screen and no drip: their hooks run a small shell
/// script, `drip-remote-hook`, that appends each event to a queue file there, and `drip follow`
/// on the Mac reads the queue over ssh and shows each event's card by the same rules as
/// `drip hook`.
public enum RemoteHook {
    /// The command the remote machine's agent hooks run, as `drip setup <agent> --remote` prints them.
    public static func command(for agent: AgentHook.Agent) -> String {
        "drip-remote-hook \(agent.rawValue)"
    }

    /// The queue file on the remote machine, as its shell spells it.
    public static let defaultQueue = "${XDG_STATE_HOME:-$HOME/.local/state}/drip/remote.jsonl"

    /// The size past which the hook moves the queue to `<queue>.1`, replacing the one before, so the
    /// two never take more than twice this, plus one event.
    public static let rotateSize = 8 * 1024 * 1024

    /// The variables of the agent's session the hook passes on: the ones `drip hook` reads to decide
    /// whether the session raises cards, and herdr's ids for the pane, tab and workspace it runs in.
    public static let sessionVariables = [
        "DRIP_HOOK", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_ENTRYPOINT",
        "HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID",
    ]

    /// `drip-remote-hook`, as `drip setup remote` prints it: POSIX sh, for a machine without drip.
    /// It never fails or holds up the agent's turn: it prints nothing and exits 0 whatever happens.
    public static var script: String {
        let variables = sessionVariables.map { "\"\($0)\":\"%s\"" }.joined(separator: ",")
        let values = sessionVariables.map { "\"$(word \"${\($0)-}\")\"" }.joined(separator: " ")
        return #"""
            #!/bin/sh
            # drip-remote-hook: queues a coding agent's hook event for `drip follow` on a Mac.
            # Written by `drip setup remote`. The agent's hooks run it as `drip hook` runs on a Mac:
            #
            #   drip-remote-hook claude|codex|gemini [payload]
            #
            # with the hook's JSON on stdin, or as an argument, as Codex's notify passes it. It appends
            # one line to $DRIP_QUEUE, or \#(defaultQueue),
            # with the payload, the agent, this machine's name ($DRIP_MACHINE, or uname -n), and the
            # session's DRIP_HOOK, Claude Code attendance and herdr pane, tab and workspace ids. It
            # never fails or holds up the agent's turn: it prints nothing and exits 0.

            drip_queue() {
                case ${1-} in claude | codex | gemini) agent=$1 ;; *) return 1 ;; esac
                queue=${DRIP_QUEUE:-\#(defaultQueue)}
                dir=$(dirname "$queue")
                umask 077
                mkdir -p "$dir" || return 1
                event=$(mktemp "$dir/.event.XXXXXX") || return 1
                trap 'rm -f "$event" "$event.payload"' EXIT
                if [ $# -ge 2 ]; then printf '%s' "$2"; else cat; fi >"$event.payload" || return 1
                size=$(wc -c <"$event.payload" | tr -d ' ')
                # drip reads up to 4 MB of payload.
                [ "$size" -gt 0 ] && [ "$size" -le 4194304 ] || return 1
                machine=$(printf '%s' "${DRIP_MACHINE:-$(uname -n)}" | tr -cd 'A-Za-z0-9._-' | cut -c 1-64)
                {
                    printf '{"drip":1,"time":%s,"agent":"%s","machine":"%s","env":{\#(variables)},"payload":' \
                        "$(date +%s)" "$agent" "${machine:-remote}" \#(values)
                    # A JSON payload holds line breaks only between its values, where a space reads the same.
                    tr '\r\n' '  ' <"$event.payload"
                    printf '}\n'
                } >"$event" || return 1
                if command -v flock >/dev/null 2>&1; then
                    (flock -w 2 9 && append) 9>>"$queue.lock"
                else
                    append
                fi
            }

            # A value as it goes in the line: letters, digits and . _ : @ - only, so it needs no quoting.
            word() {
                printf '%s' "$1" | tr -cd 'A-Za-z0-9._:@-' | cut -c 1-64
            }

            # Appends the event, first moving a queue past \#(rotateSize) bytes to $queue.1.
            append() {
                if [ -f "$queue" ]; then
                    set -- $(ls -ln "$queue")
                    if [ "$5" -gt \#(rotateSize) ]; then mv -f "$queue" "$queue.1"; fi
                fi
                cat "$event" >>"$queue"
            }

            (drip_queue "$@") >/dev/null 2>&1
            exit 0

            """#
    }
}

extension AgentHook {
    /// Another machine an agent runs on, as `drip follow` hears from it.
    public struct Origin: Equatable, Sendable {
        /// The machine's name, as its hook gave it: card ids and titles carry it.
        public var machine: String
        /// The app a click on the card brings forward; nil for none.
        public var activate: String?
        /// The agent's herdr tab on the machine, which a click focuses once `activate` is in front.
        public var pane: TerminalPane?

        public init(machine: String, activate: String? = nil, pane: TerminalPane? = nil) {
            self.machine = machine
            self.activate = activate
            self.pane = pane
        }

        /// A session's id on this machine: `<agent>:<session>@<machine>`, so it never replaces the
        /// card of a session on this Mac or on another machine.
        public func qualified(_ id: String) -> String {
            "\(id)@\(machine)"
        }
    }
}

/// One event in the remote machine's queue, as `drip-remote-hook` writes it: a JSON object on one
/// line with `drip` (the format, 1), `time` (seconds since 1970, on the remote clock), `agent`,
/// `machine`, `env` (the session's variables, `RemoteHook.sessionVariables`) and `payload` (the
/// hook's JSON).
public struct RemoteEvent: Equatable, Sendable {
    public var time: Double
    public var agent: AgentHook.Agent
    public var machine: String
    /// The session's variables, as the hook found them; empty ones left out.
    public var environment: [String: String]
    /// The hook's JSON.
    public var payload: String

    public init(time: Double, agent: AgentHook.Agent, machine: String, environment: [String: String], payload: String) {
        self.time = time
        self.agent = agent
        self.machine = machine
        self.environment = environment
        self.payload = payload
    }

    /// Reads a line of the queue. Throws a `UsageError` for one that is not an event drip knows.
    public init(line: String) throws {
        guard let object = try? JSONValue(parsing: line), object.members != nil else {
            throw UsageError("not a JSON object")
        }
        guard case .number("1")? = object["drip"] else {
            throw UsageError("not a drip-remote-hook event of format 1")
        }
        guard case let .number(time)? = object["time"], let seconds = Double(time) else {
            throw UsageError("no time")
        }
        guard let name = object["agent"]?.string, let agent = AgentHook.Agent(rawValue: name) else {
            throw UsageError("no agent drip knows")
        }
        guard let machine = object["machine"]?.string, TerminalPane.isMachineLabel(machine) else {
            throw UsageError("no machine name")
        }
        guard let payload = object["payload"], payload.members != nil else {
            throw UsageError("no payload")
        }
        var environment: [String: String] = [:]
        for member in object["env"]?.members ?? [] where RemoteHook.sessionVariables.contains(member.key) {
            if let value = member.value.string, !value.isEmpty { environment[member.key] = value }
        }
        self.init(time: seconds, agent: agent, machine: machine, environment: environment, payload: payload.formatted())
    }

    /// The variables of a session on this Mac, which an event from another machine never takes.
    static let localSessionVariables = RemoteHook.sessionVariables + [
        "HERDR_ENV", "HERDR_SOCKET_PATH", "TMUX", "TMUX_PANE", "WEZTERM_PANE", CardActivation.senderVariable,
    ]

    /// The environment the hook's rules read for this event: `local`, `drip follow`'s own, for the
    /// config, the state and the `DRIP_*` settings, with the session's variables from the event.
    public func environment(over local: [String: String]) -> [String: String] {
        var merged = local.filter { !Self.localSessionVariables.contains($0.key) }
        for name in ["DRIP_HOOK", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_ENTRYPOINT"] {
            merged[name] = environment[name]
        }
        return merged
    }

    /// Where the event came from, for `AgentHook.card`: its machine, the app a click brings forward,
    /// and the agent's herdr tab on the saved herdr machine `herdrMachine`, when herdr names one.
    public func origin(activate: String?, herdrMachine: String?) -> AgentHook.Origin {
        AgentHook.Origin(
            machine: machine, activate: activate,
            pane: herdrMachine.flatMap { TerminalPane(herdrMachine: $0, environment: environment) })
    }

    /// Seconds between the event and `now`; none for an event from a remote clock ahead of this one.
    public func age(now: Double) -> Double {
        max(0, now - time)
    }
}

/// Where `drip follow` is in the remote queue: the queue file, by its inode, and how many bytes of
/// it it has handled. It keeps it in `<state>/follow`, so a new connection takes up after the last
/// line handled.
public struct FollowPosition: Codable, Equatable, Sendable {
    public var inode: String
    public var offset: Int

    public init(inode: String, offset: Int) {
        self.inode = inode
        self.offset = offset
    }

    #if !os(WASI)
    /// The file the position for `target` is kept in.
    public static func path(target: String, environment: [String: String]) -> String {
        let directory = (StateDirectory.path(environment: environment) as NSString).appendingPathComponent("follow")
        return (directory as NSString).appendingPathComponent("\(AgentHook.fingerprint(target)).json")
    }

    public static func load(from path: String) -> FollowPosition? {
        FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(FollowPosition.self, from: $0) }
    }

    public func save(to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try StateFiles.write(String(decoding: try JSONEncoder().encode(self), as: UTF8.self) + "\n", toPath: path)
    }
    #endif
}

/// What `drip follow` runs on the remote machine, with `sh -s`, and how it reads what comes back.
///
/// The reader checks the queue every second and prints the whole lines added since it last looked,
/// so a line being written never comes out in halves. It says which file it reads with
/// `#file <inode> <offset>` when it starts on one, and prints `#` every 15 seconds when there is
/// nothing new, so a connection gone quiet is told from one that died. When the queue has moved to
/// `<queue>.1` it finishes that file first.
public enum FollowReader {
    /// How often the reader says it is still there.
    public static let heartbeat = 15.0

    /// The reader, starting after `position`, or at the end of the queue when nil, so a first
    /// `drip follow` shows only what comes next. `queue` is the queue's path on the remote machine,
    /// nil for `RemoteHook.defaultQueue`.
    public static func script(queue: String?, position: FollowPosition?) -> String {
        let queueLine = queue.map { "queue=\(ShellWord.singleQuoted($0))" }
            ?? "queue=${DRIP_QUEUE:-\(RemoteHook.defaultQueue)}"
        let inode = position.map(\.inode).flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil } ?? ""
        return #"""
            \#(queueLine)
            inode=\#(inode)
            off=\#(position?.offset ?? 0)
            tmp=$(mktemp) || exit 1
            trap 'rm -f "$tmp" "$tmp.lines"' EXIT
            trap 'exit 0' HUP INT TERM PIPE

            # The file's inode and size, or nothing when it is missing.
            identify() {
                [ -f "$1" ] || return 0
                set -- $(ls -iln "$1")
                echo "$1 $6"
            }

            # Prints the whole lines of the file from byte $off on, and moves $off past them.
            emit() {
                tail -c +$((off + 1)) "$1" >"$tmp" 2>/dev/null || return 0
                [ -s "$tmp" ] || return 0
                if [ "$(tail -c 1 "$tmp" | wc -l | tr -d ' ')" -eq 0 ]; then
                    sed '$d' "$tmp" >"$tmp.lines"
                else
                    mv -f "$tmp" "$tmp.lines"
                fi
                n=$(wc -c <"$tmp.lines" | tr -d ' ')
                [ "$n" -gt 0 ] || return 0
                cat "$tmp.lines" || exit 0
                off=$((off + n))
            }

            echo '#drip-follow 1'
            quiet=0
            while :; do
                found=$(identify "$queue")
                if [ -n "$found" ]; then
                    now=${found% *}
                    size=${found#* }
                    if [ "$now" != "$inode" ]; then
                        if [ -z "$inode" ] && [ -z "$started" ]; then
                            # A first follow starts at the end: only what comes next.
                            off=$size
                        else
                            # The queue moved to .1 since: the rest of it first, when it is still there.
                            old=$(identify "$queue.1")
                            if [ -n "$inode" ] && [ "${old% *}" = "$inode" ]; then emit "$queue.1"; fi
                            off=0
                        fi
                        inode=$now
                        echo "#file $inode $off"
                    elif [ "$size" -lt "$off" ]; then
                        # Cut short in place: it starts over.
                        off=0
                        echo "#file $inode $off"
                    fi
                    before=$off
                    emit "$queue"
                    [ "$off" -eq "$before" ] || quiet=0
                fi
                started=1
                quiet=$((quiet + 1))
                if [ "$quiet" -ge \#(Int(heartbeat)) ]; then
                    echo '#' || exit 0
                    quiet=0
                fi
                sleep 1
            done

            """#
    }

    /// What one line from the reader says.
    public enum Line: Equatable {
        /// The reader started.
        case hello
        /// The reader is still there, with nothing new.
        case heartbeat
        /// The reader reads the queue file with this inode, from this offset.
        case file(FollowPosition)
        /// A line of the queue: the event, or why it is not one.
        case event(Result<RemoteEvent, UsageError>)
    }

    /// Splits what the reader prints into lines, and keeps the position in the queue: past each
    /// line of it, however it reads.
    public struct Stream {
        /// The longest line drip reads: an event with a payload of `AgentHook.payloadLimit`.
        public static let lineLimit = AgentHook.payloadLimit + 64 * 1024

        public private(set) var position: FollowPosition?
        private var buffer: [UInt8] = []
        /// Bytes of a line too long to read, which is skipped to its end.
        private var skipped: Int?

        public init(position: FollowPosition?) {
            self.position = position
        }

        /// The lines `bytes` completes, each with the position after it.
        public mutating func read(_ bytes: [UInt8]) -> [(Line, FollowPosition?)] {
            var lines: [(Line, FollowPosition?)] = []
            for byte in bytes {
                if byte != UInt8(ascii: "\n") {
                    if let count = skipped {
                        skipped = count + 1
                    } else if buffer.count < Self.lineLimit {
                        buffer.append(byte)
                    } else {
                        skipped = buffer.count + 1
                        buffer = []
                    }
                    continue
                }
                if let count = skipped {
                    skipped = nil
                    advance(by: count + 1)
                    lines.append((.event(.failure(UsageError("a line longer than \(Self.lineLimit) bytes"))), position))
                    continue
                }
                let text = String(decoding: buffer, as: UTF8.self)
                let size = buffer.count + 1
                buffer = []
                if text.hasPrefix("#") {
                    lines.append((control(text), position))
                    continue
                }
                advance(by: size)
                do {
                    lines.append((.event(.success(try RemoteEvent(line: text))), position))
                } catch let error as UsageError {
                    lines.append((.event(.failure(error)), position))
                } catch {
                    lines.append((.event(.failure(UsageError("\(error)"))), position))
                }
            }
            return lines
        }

        private mutating func advance(by count: Int) {
            position?.offset += count
        }

        private mutating func control(_ text: String) -> Line {
            let words = text.split(separator: " ")
            if words.first == "#file", words.count == 3, let offset = Int(words[2]) {
                position = FollowPosition(inode: String(words[1]), offset: offset)
                return .file(FollowPosition(inode: String(words[1]), offset: offset))
            }
            return text.hasPrefix("#drip-follow") ? .hello : .heartbeat
        }
    }
}

extension ShellWord {
    /// `text` in single quotes, for a POSIX shell to read back as it is.
    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacing("'", with: "'\\''") + "'"
    }
}
