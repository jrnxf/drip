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
    /// The queue file on the remote machine, as its shell spells it.
    public static let defaultQueue = "${XDG_STATE_HOME:-$HOME/.local/state}/drip/remote.jsonl"

    /// The size past which the hook moves the queue to `<queue>.1`, replacing the one before, so the
    /// two never take more than twice this, plus one event.
    public static let rotateSize = 8 * 1024 * 1024

    /// The variables of the agent's session the hook passes on in `env`: the ones `drip hook` reads
    /// to decide whether the session raises cards. The ones `DRIP_FORWARD_ENV` names go in `forward`,
    /// which only a click's `--on-click` command reads.
    public static let sessionVariables = ["DRIP_HOOK", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_ENTRYPOINT"]

    /// `drip-remote-hook`, as `drip remote-hook` prints it: POSIX sh, for a machine without drip.
    /// It never fails or holds up the agent's turn: it prints nothing and exits 0 whatever happens.
    public static var script: String {
        let variables = sessionVariables.map { "\"\($0)\":\"%s\"" }.joined(separator: ",")
        let values = sessionVariables.map { "\"$(word \"${\($0)-}\")\"" }.joined(separator: " ")
        return #"""
            #!/bin/sh
            # drip-remote-hook: queues a coding agent's hook event for `drip follow` on a Mac.
            # Printed by `drip remote-hook`. The agent's hooks run it as `drip hook` runs on a Mac:
            #
            #   drip-remote-hook claude|codex|gemini [--min-turn SECONDS] [--only needs-you] [payload]
            #
            # with the hook's JSON on stdin, or as an argument, as Codex's notify passes it. It appends
            # one line to $DRIP_QUEUE, or \#(defaultQueue),
            # with the payload, the agent, this machine's name ($DRIP_MACHINE, or uname -n), the
            # session's DRIP_HOOK and Claude Code attendance, the two flags above, which drip follow
            # applies as drip hook does, and the variables DRIP_FORWARD_ENV names, separated by spaces,
            # for a click's --on-click command on the Mac. --approve is accepted and ignored: an
            # agent on another machine cannot hear a click. It never fails or holds up the agent's
            # turn: it prints nothing and exits 0.

            drip_queue() {
                case ${1-} in claude | codex | gemini) agent=$1 ;; *) return 1 ;; esac
                shift
                min_turn=
                only=
                payload_arg=0
                while [ $# -gt 0 ]; do
                    case $1 in
                        --min-turn) [ $# -ge 2 ] || return 1; min_turn=$(printf '%s' "$2" | tr -cd '0-9.' | cut -c 1-8); shift 2 ;;
                        --only) [ $# -ge 2 ] || return 1; [ "$2" = needs-you ] && only=$2; shift 2 ;;
                        --approve) shift ;;
                        -*) shift ;;
                        *) payload_arg=1; payload=$1; break ;;
                    esac
                done
                queue=${DRIP_QUEUE:-\#(defaultQueue)}
                dir=$(dirname "$queue")
                umask 077
                mkdir -p "$dir" || return 1
                event=$(mktemp "$dir/.event.XXXXXX") || return 1
                trap 'rm -f "$event" "$event.payload"; [ -z "${held-}" ] || rm -rf "$held"' EXIT
                if [ "$payload_arg" -eq 1 ]; then printf '%s' "$payload"; else cat; fi >"$event.payload" || return 1
                size=$(wc -c <"$event.payload" | tr -d ' ')
                # drip reads up to 4 MB of payload.
                [ "$size" -gt 0 ] && [ "$size" -le 4194304 ] || return 1
                # Letters, digits and . _ - only, starting with a letter or digit, as a host name may be.
                machine=$(printf '%s' "${DRIP_MACHINE:-$(uname -n)}" | tr -cd 'A-Za-z0-9._-' | sed 's/^[^A-Za-z0-9]*//' | cut -c 1-64)
                forward=$(forward)
                {
                    printf '{"drip":1,"time":%s,"agent":"%s","machine":"%s","env":{\#(variables)},"forward":{%s},"filter":{%s},"payload":' \
                        "$(date +%s)" "$agent" "${machine:-remote}" \#(values) "$forward" "$(filter)"
                    # A JSON payload holds line breaks only between its values, where a space reads the same.
                    tr '\r\n' '  ' <"$event.payload"
                    printf '}\n'
                } >"$event" || return 1
                if command -v flock >/dev/null 2>&1; then
                    (flock -w 2 9 && append) 9>>"$queue.lock"
                else
                    # The lock is released when this subshell ends, by the trap above.
                    lock_dir && append
                fi
            }

            # Takes the lock where there is no flock, as on macOS and with busybox: mkdir makes the
            # directory or fails in one step. Waits 2 seconds, like flock -w 2. A holder that died
            # leaves its directory behind: after the wait it is taken over unless its process lives,
            # and one with no pid yet gets another wait, as it may be between its mkdir and its pid.
            lock_dir() {
                lockdir="$queue.lockdir"
                tries=0
                waits=0
                until mkdir "$lockdir" 2>/dev/null; do
                    if sleep 0.1 2>/dev/null; then tries=$((tries + 1)); else sleep 1; tries=$((tries + 10)); fi
                    [ "$tries" -gt 20 ] || continue
                    tries=0
                    waits=$((waits + 1))
                    [ "$waits" -le 2 ] || return 1
                    pid=$(cat "$lockdir/pid" 2>/dev/null)
                    if [ -n "$pid" ]; then
                        if kill -0 "$pid" 2>/dev/null; then return 1; fi
                    elif [ "$waits" -eq 1 ]; then
                        continue
                    fi
                    # One waiter at a time breaks it, and only while it is still the one found dead.
                    if mkdir "$lockdir/break" 2>/dev/null; then
                        if [ "$(cat "$lockdir/pid" 2>/dev/null)" = "$pid" ] && mv "$lockdir" "$lockdir.$$" 2>/dev/null; then
                            rm -rf "$lockdir.$$"
                        else
                            rmdir "$lockdir/break" 2>/dev/null
                        fi
                    fi
                done
                held=$lockdir
                echo $$ >"$lockdir/pid"
                return 0
            }

            # A value as it goes in the line: letters, digits and . _ : @ - only, so it needs no quoting.
            word() {
                printf '%s' "$1" | tr -cd 'A-Za-z0-9._:@-' | cut -c 1-64
            }

            # The members of "filter": the flags the hook was given that drip follow applies, each only
            # when it is set and valid.
            filter() {
                members=
                case $min_turn in '' | *[!0-9.]* | *.*.* | .) ;; *) members="\"min_turn\":\"$min_turn\"" ;; esac
                [ -z "$only" ] || members="$members${members:+,}\"only\":\"$only\""
                printf '%s' "$members"
            }

            # The members of "forward": each variable DRIP_FORWARD_ENV names, up to \#(ForwardedEnvironment.countLimit), that is
            # set and not empty. A name must be a variable's name; a value keeps letters, digits and
            # . _ : @ / % + , = - only, up to \#(ForwardedEnvironment.valueLimit) characters, so it needs no quoting.
            forward() {
                set -f
                count=0
                members=
                for name in ${DRIP_FORWARD_ENV-}; do
                    case $name in '' | [!A-Za-z_]* | *[!A-Za-z0-9_]*) continue ;; esac
                    [ "${#name}" -le \#(ForwardedEnvironment.nameLimit) ] || continue
                    count=$((count + 1))
                    [ "$count" -le \#(ForwardedEnvironment.countLimit) ] || break
                    eval "value=\${$name-}"
                    value=$(printf '%s' "$value" | tr -cd 'A-Za-z0-9._:@/%+,=-' | cut -c 1-\#(ForwardedEnvironment.valueLimit))
                    [ -n "$value" ] || continue
                    members="$members${members:+,}\"$name\":\"$value\""
                done
                printf '%s' "$members"
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
            # An agent that writes the payload to stdin gets a broken pipe if the hook ends before
            # reading it, as when the event was not queued: read the rest, unless it came as an argument.
            argument=0
            skip=1
            for word in "$@"; do
                if [ "$skip" -eq 1 ]; then skip=0; continue; fi
                case $word in
                    --min-turn | --only) skip=1 ;;
                    --approve | -*) ;;
                    *) argument=1; break ;;
                esac
            done
            [ "$argument" -eq 1 ] || [ -t 0 ] || cat >/dev/null 2>&1
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
        /// The command a click on the card runs, from `drip follow --on-click` on this Mac; nil for none.
        public var onClick: String?
        /// The variables `DRIP_FORWARD_ENV` named in the agent's session, for `onClick` to read.
        public var forwarded: [String: String]

        public init(machine: String, activate: String? = nil, onClick: String? = nil, forwarded: [String: String] = [:]) {
            self.machine = machine
            self.activate = activate
            self.onClick = onClick
            self.forwarded = forwarded
        }

        /// What a click on the card runs: `onClick`, with the machine and its forwarded variables.
        public var click: OnClick? {
            onClick.map { OnClick(command: $0, machine: machine, environment: forwarded) }
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
/// `machine`, `env` (the session's variables, `RemoteHook.sessionVariables`), `forward` (the
/// variables `DRIP_FORWARD_ENV` names), `filter` (the hook's `--min-turn` and `--only`) and
/// `payload` (the hook's JSON). drip reads nothing else from
/// it: a click's command, and what a button opens, come only from this Mac.
public struct RemoteEvent: Equatable, Sendable {
    public var time: Double
    public var agent: AgentHook.Agent
    public var machine: String
    /// The session's variables, as the hook found them; empty ones left out.
    public var environment: [String: String]
    /// The variables `DRIP_FORWARD_ENV` named in the session, which only a click's command reads.
    public var forwarded: [String: String]
    /// What the hook's flags asked: `--min-turn` and `--only`. Never `approve`.
    public var policy: AgentHook.Policy
    /// The hook's JSON.
    public var payload: String

    public init(
        time: Double, agent: AgentHook.Agent, machine: String, environment: [String: String],
        forwarded: [String: String] = [:], policy: AgentHook.Policy = AgentHook.Policy(), payload: String
    ) {
        self.policy = policy
        self.time = time
        self.agent = agent
        self.machine = machine
        self.environment = environment
        self.forwarded = forwarded
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
        guard let machine = object["machine"]?.string, Self.isMachineName(machine) else {
            throw UsageError("no machine name")
        }
        guard let payload = object["payload"], payload.members != nil else {
            throw UsageError("no payload")
        }
        var environment: [String: String] = [:]
        for member in object["env"]?.members ?? [] where RemoteHook.sessionVariables.contains(member.key) {
            if let value = member.value.string, !value.isEmpty { environment[member.key] = value }
        }
        self.init(
            time: seconds, agent: agent, machine: machine, environment: environment,
            forwarded: ForwardedEnvironment.read(members: object["forward"]?.members ?? []),
            policy: Self.policy(object["filter"]), payload: payload.formatted())
    }

    /// The flags a hook queued, as text. A value drip does not know is left out, as the hook leaves
    /// it out, so a newer hook never makes an older drip fail.
    static func policy(_ filter: JSONValue?) -> AgentHook.Policy {
        var policy = AgentHook.Policy()
        if let text = filter?["min_turn"]?.string, let seconds = Double(text), AgentHook.Policy.minTurnRange.contains(seconds) {
            policy.minTurn = seconds
        }
        if let text = filter?["only"]?.string { policy.only = AgentHook.Policy.Only(rawValue: text) }
        return policy
    }

    /// The variables of a session on this Mac, which an event from another machine never takes.
    static let localSessionVariables = RemoteHook.sessionVariables + [
        "TMUX", "TMUX_PANE", CardActivation.senderVariable, ForwardedEnvironment.variable,
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
    /// the command a click runs, `drip follow --on-click`, and the variables the session forwarded.
    public func origin(activate: String?, onClick: String?) -> AgentHook.Origin {
        AgentHook.Origin(machine: machine, activate: activate, onClick: onClick, forwarded: forwarded)
    }

    /// A machine's name, as the hook writes it: letters, digits, dots, hyphens and underscores,
    /// starting with a letter or digit, up to 64.
    static func isMachineName(_ text: String) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter || first.isNumber, text.count <= 64 else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }

    /// Seconds between the event and `now`; none for an event from a remote clock ahead of this one.
    public func age(now: Double) -> Double {
        max(0, now - time)
    }
}

/// Where `drip follow` is in the remote queue: the queue file, by its inode and a fingerprint of its
/// first line, and how many bytes of it it has handled. It keeps it in `<state>/follow`, so a new
/// connection takes up after the last line handled.
public struct FollowPosition: Codable, Equatable, Sendable {
    public var inode: String
    public var offset: Int
    /// The fingerprint of the queue's first line, which tells a new queue from the one read before
    /// when it takes the inode a rotated one freed. Nil until the queue has a whole line, and in a
    /// position kept by an older drip, which the inode alone identifies.
    public var id: String?

    public init(inode: String, offset: Int, id: String? = nil) {
        self.inode = inode
        self.offset = offset
        self.id = id
    }

    /// Whether `text` is a fingerprint the reader prints: digits and hyphens.
    static func isID(_ text: some StringProtocol) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "-") }
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
/// The reader starts with `#drip-follow 2 <time>`, then checks the queue every second and prints the
/// whole lines added since it last looked, each after a `=`, so a line being written never comes out
/// in halves, and nothing else the remote shell prints, such as a banner from its startup files, is
/// taken for one. It says which file it reads with `#file <inode> <offset> <id>` when it starts on
/// one (`<id>` is left out until the file has a whole first line), `#missing <path>` when there is
/// no queue to read, and prints `# <time>` every 15 seconds when there is nothing new, so a
/// connection gone quiet is told from one that died. `<time>` is the machine's own clock, seconds
/// since 1970, which tells `drip follow` how far it is from this Mac's; a line without it says
/// nothing of the clock. When the queue has moved to `<queue>.1` it finishes that file first.
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
        let id = position?.id.flatMap { FollowPosition.isID($0) ? $0 : nil } ?? ""
        return #"""
            \#(queueLine)
            inode=\#(inode)
            fid=\#(id)
            off=\#(position?.offset ?? 0)
            started=
            missing=
            tmp=$(mktemp) || exit 1
            trap 'rm -f "$tmp" "$tmp.lines" "$tmp.id"' EXIT
            trap 'exit 0' HUP INT TERM PIPE

            # The file's inode and size, or nothing when it is missing.
            identify() {
                [ -f "$1" ] || return 0
                set -- $(ls -iln "$1")
                echo "$1 $6"
            }

            # A fingerprint of the file's first line, nothing until it has a whole one: a new queue can
            # take the inode a rotated one freed, which the inode alone would not tell apart.
            fileid() {
                [ -f "$1" ] || return 0
                head -n 1 "$1" >"$tmp.id" 2>/dev/null || return 0
                [ "$(wc -l <"$tmp.id" | tr -d ' ')" -eq 1 ] || return 0
                set -- $(cksum <"$tmp.id")
                echo "$1-$2"
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
                sed 's/^/=/' "$tmp.lines" || exit 0
                off=$((off + n))
            }

            echo "#drip-follow 2 $(date +%s)"
            quiet=0
            while :; do
                found=$(identify "$queue")
                if [ -z "$found" ] && [ -z "$missing" ]; then
                    echo "#missing $queue"
                    missing=1
                fi
                if [ -n "$found" ]; then
                    missing=
                    now=${found% *}
                    size=${found#* }
                    id=
                    if [ "$now" != "$inode" ] || [ -z "$started" ] || [ -z "$fid" ]; then id=$(fileid "$queue"); fi
                    moved=
                    if [ "$now" != "$inode" ]; then
                        moved=1
                    elif [ -n "$id" ] && [ -n "$fid" ] && [ "$id" != "$fid" ]; then
                        # Another file with the inode of the one read: it was rotated away and replaced.
                        moved=1
                    fi
                    if [ -n "$moved" ]; then
                        if [ -z "$inode" ] && [ -z "$started" ]; then
                            # A first follow starts at the end: only what comes next.
                            off=$size
                        else
                            # The queue moved to .1 since: the rest of it first, when it is still there.
                            old=$(identify "$queue.1")
                            oldid=$(fileid "$queue.1")
                            if [ -n "$inode" ] && [ "${old% *}" = "$inode" ] \
                                && { [ -z "$fid" ] || [ -z "$oldid" ] || [ "$oldid" = "$fid" ]; }; then
                                emit "$queue.1"
                            fi
                            off=0
                        fi
                        inode=$now
                        fid=$id
                        echo "#file $inode $off${fid:+ $fid}"
                    elif [ "$size" -lt "$off" ]; then
                        # Cut short in place: it starts over, and its first line is another.
                        off=0
                        fid=
                        echo "#file $inode $off${fid:+ $fid}"
                    elif [ -z "$fid" ] && [ -n "$id" ]; then
                        # The queue has a whole first line now.
                        fid=$id
                        echo "#file $inode $off $fid"
                    fi
                    before=$off
                    emit "$queue"
                    [ "$off" -eq "$before" ] || quiet=0
                fi
                started=1
                quiet=$((quiet + 1))
                if [ "$quiet" -ge \#(Int(heartbeat)) ]; then
                    echo "# $(date +%s)" || exit 0
                    quiet=0
                fi
                sleep 1
            done

            """#
    }

    /// What one line from the reader says.
    public enum Line: Equatable {
        /// The reader started, with the machine's clock when it said it: seconds since 1970.
        case hello(time: Double?)
        /// The reader is still there, with nothing new, and the machine's clock when it said it.
        case heartbeat(time: Double?)
        /// The reader reads the queue file with this inode and first line, from this offset.
        case file(FollowPosition)
        /// There is no queue at this path on the machine.
        case missing(String)
        /// A line of the queue: the event, or why it is not one.
        case event(Result<RemoteEvent, UsageError>)
        /// Something else the remote shell printed, such as a banner from its startup files, which
        /// is no part of the queue.
        case noise(String)
    }

    /// Splits what the reader prints into lines, and keeps the position in the queue: past each
    /// line of it, however it reads, and past nothing else.
    public struct Stream {
        /// The longest line drip reads: an event with a payload of `AgentHook.payloadLimit`.
        public static let lineLimit = AgentHook.payloadLimit + 64 * 1024

        public private(set) var position: FollowPosition?
        private var buffer: [UInt8] = []
        /// Bytes of a line too long to read, which is skipped to its end, and whether it is a line of
        /// the queue.
        private var skipped: (count: Int, queued: Bool)?
        /// Whether the reader said it started: what comes before is the remote shell's.
        private var started = false

        public init(position: FollowPosition?) {
            self.position = position
        }

        /// The lines `bytes` completes, each with the position after it.
        public mutating func read(_ bytes: [UInt8]) -> [(Line, FollowPosition?)] {
            var lines: [(Line, FollowPosition?)] = []
            for byte in bytes {
                if byte != UInt8(ascii: "\n") {
                    if let line = skipped {
                        skipped = (line.count + 1, line.queued)
                    } else if buffer.count < Self.lineLimit {
                        buffer.append(byte)
                    } else {
                        skipped = (buffer.count + 1, started && buffer.first == Self.queued)
                        buffer = []
                    }
                    continue
                }
                if let line = skipped {
                    skipped = nil
                    if line.queued {
                        // The queue's own line, without the `=` before it, and its line break.
                        advance(by: line.count)
                        lines.append((.event(.failure(UsageError("a line longer than \(Self.lineLimit) bytes"))), position))
                    } else {
                        lines.append((.noise("a line longer than \(Self.lineLimit) bytes"), position))
                    }
                    continue
                }
                let line = buffer
                buffer = []
                lines.append((self.line(line), position))
            }
            return lines
        }

        /// What comes before a line of the queue.
        static let queued = UInt8(ascii: "=")

        private mutating func line(_ bytes: [UInt8]) -> Line {
            let text = String(decoding: bytes, as: UTF8.self)
            guard started else {
                if text == "#drip-follow 2" { started = true; return .hello(time: nil) }
                if text.hasPrefix("#drip-follow 2 ") {
                    started = true
                    return .hello(time: Self.clock(text.dropFirst(15)))
                }
                return .noise(text)
            }
            guard bytes.first == Self.queued else { return control(text) }
            advance(by: bytes.count)
            do {
                return .event(.success(try RemoteEvent(line: String(text.dropFirst()))))
            } catch let error as UsageError {
                return .event(.failure(error))
            } catch {
                return .event(.failure(UsageError("\(error)")))
            }
        }

        private mutating func advance(by count: Int) {
            position?.offset += count
        }

        private mutating func control(_ text: String) -> Line {
            if text == "#" { return .heartbeat(time: nil) }
            if text.hasPrefix("# ") { return .heartbeat(time: Self.clock(text.dropFirst(2))) }
            if text.hasPrefix("#missing ") { return .missing(String(text.dropFirst(9))) }
            let words = text.split(separator: " ")
            if words.first == "#file", words.count == 3 || words.count == 4, words[1].allSatisfy(\.isNumber),
               let offset = Int(words[2]), words.count == 3 || FollowPosition.isID(words[3]) {
                let file = FollowPosition(inode: String(words[1]), offset: offset, id: words.count == 4 ? String(words[3]) : nil)
                position = file
                return .file(file)
            }
            return .noise(text)
        }

        /// The machine's clock in a line of the reader; nil for none, or something else.
        private static func clock(_ text: Substring) -> Double? {
            text.allSatisfy { $0.isASCII && $0.isNumber } ? Double(text) : nil
        }
    }
}

extension ShellWord {
    /// `text` in single quotes, for a POSIX shell to read back as it is.
    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacing("'", with: "'\\''") + "'"
    }
}
