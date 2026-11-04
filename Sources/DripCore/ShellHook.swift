#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// `drip setup zsh`: a card for any command that ran long, without `drip run` in front of it.
///
/// The hook is shell code in `~/.zshrc`. It notes when each command starts, and when the prompt comes
/// back it compares the time with a threshold in the shell itself, so a fast command never starts a
/// drip. Only a slow one does, through `drip __finished`, which shows the card unless you are
/// watching that terminal.
public enum ShellHook {
    public enum Shell: String, CaseIterable, Sendable {
        case zsh
    }

    /// How many seconds a command runs before it gets a card, unless `DRIP_SLOW_AFTER` says otherwise.
    public static let defaultAfter = 10

    /// The commands that take over the terminal, or wait for you in it: finishing one says nothing.
    /// `DRIP_SLOW_IGNORE` adds to them.
    public static let defaultIgnore = [
        "vim", "vi", "nvim", "view", "nano", "pico", "micro", "emacs", "hx", "kak",
        "less", "more", "most", "man", "info", "bat", "tail", "watch",
        "ssh", "mosh", "telnet", "sftp", "ftp", "nc", "screen", "tmux", "zellij", "herdr",
        "top", "htop", "btop", "glances", "nvtop",
        "python", "python3", "node", "deno", "bun", "irb", "pry", "ipython", "lua", "ghci", "psql", "mysql", "sqlite3",
        "redis-cli", "mongosh", "gdb", "lldb",
        "claude", "codex", "gemini", "aider", "opencode",
        "fzf", "nnn", "lf", "ranger", "yazi", "mc", "tig", "lazygit", "k9s",
        "fg", "bg", "su", "zsh", "bash", "fish", "sh", "drip",
    ]

    /// The first and last line of the block setup adds to the rc file, which setup finds again to
    /// bring it up to date.
    public static let begin = "# >>> drip: a card when a slow command finishes >>>"
    public static let end = "# <<< drip <<<"

    /// The environment variable that keeps the hook silent: an orchestrator sets it for the workers it
    /// starts, whose finished commands are no news to you.
    public static let silencedBy = "FM_TASK_ID"

    /// The block setup adds to the rc file, begin and end lines included, ending with a newline.
    public static func snippet(for shell: Shell) -> String {
        switch shell {
        case .zsh: return zsh
        }
    }

    /// The rc file the block goes in, from the environment: `.zshrc` in `ZDOTDIR`, else the home directory.
    public static func rcPath(for shell: Shell, environment: [String: String]) -> String {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "~"
        switch shell {
        case .zsh:
            let directory = environment["ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home
            return directory + "/.zshrc"
        }
    }

    private static var zsh: String {
        let ignore = defaultIgnore.joined(separator: " ")
        return #"""
            \#(begin)
            # Written by `drip setup zsh`: run it again to update this block, delete it to remove it.
            # A command that runs \#(defaultAfter) seconds or more shows a card when it ends, unless you are
            # watching this terminal. No drip runs for a faster command.
            #   DRIP_SLOW_AFTER   seconds a command must run for a card; 0 turns the cards off
            #   DRIP_SLOW_IGNORE  more commands to leave out, space-separated, besides the editors, pagers,
            #                     ssh and REPLs named below
            # Silent where drip is missing, and where \#(silencedBy) is set or DRIP_HOOK=off.
            if zmodload zsh/datetime 2>/dev/null && autoload -Uz add-zsh-hook 2>/dev/null; then
              typeset -g __drip_command __drip_expanded
              typeset -gF __drip_start=0
              typeset -ga __drip_ignore=(\#(ignore))

              __drip_preexec() {
                __drip_command=$1
                __drip_expanded=$3
                __drip_start=$EPOCHREALTIME
              }

              # Whether the command line starts a command in the ignore list, past any assignments,
              # sudo and the like.
              __drip_ignored() {
                local word
                local -a ignore=($__drip_ignore ${=DRIP_SLOW_IGNORE})
                for word in ${(z)1}; do
                  case $word in
                    *=* | -* | sudo | command | builtin | exec | env | nocorrect | noglob | nohup | time) continue ;;
                  esac
                  word=${${(Q)word}:t}
                  (( ${ignore[(Ie)$word]} ))
                  return
                done
                return 1
              }

              __drip_precmd() {
                local code=$?
                [[ -n $__drip_command ]] || return $code
                local command=$__drip_command expanded=$__drip_expanded
                __drip_command=
                local seconds=$(( EPOCHREALTIME - __drip_start ))
                local after=${DRIP_SLOW_AFTER:-\#(defaultAfter)}
                (( after > 0 && seconds >= after )) || return $code
                [[ -z ${\#(silencedBy)-} && ${DRIP_HOOK-} != off ]] || return $code
                (( $+commands[drip] )) || return $code
                __drip_ignored $expanded && return $code
                command drip __finished --status $code --seconds $seconds -- $command >/dev/null 2>&1 &!
                return $code
              }

              add-zsh-hook preexec __drip_preexec
              add-zsh-hook precmd __drip_precmd
            fi
            \#(end)

            """#
    }

    /// Why setup leaves the rc file alone.
    public struct Refusal: Error, CustomStringConvertible, Equatable {
        public var description: String
    }

    public struct Merge: Equatable {
        /// The whole new file.
        public var text: String
        /// Whether the file had the block already, out of date.
        public var updated: Bool
    }

    /// The rc file's text with drip's block in it: added at the end, or, when it is there already,
    /// replaced where it stands. Nil when the file has the current block already. Throws a
    /// `Refusal` for a block that was cut in two.
    public static func merge(_ text: String?, shell: Shell) throws -> Merge? {
        let block = snippet(for: shell)
        let original = text ?? ""
        let hasBegin = original.contains(begin)
        let hasEnd = original.contains(end)
        guard hasBegin || hasEnd else {
            var result = original
            if !result.isEmpty {
                if !result.hasSuffix("\n") { result += "\n" }
                if !result.hasSuffix("\n\n") { result += "\n" }
            }
            return Merge(text: result + block, updated: false)
        }
        guard let start = original.firstRange(of: begin), let finish = original[start.upperBound...].firstRange(of: end),
              original[start.upperBound...].firstRange(of: begin) == nil
        else {
            throw Refusal(description: "has drip's block cut in two, or twice")
        }
        // The block's own end line is part of what it replaces, with its newline.
        var upper = finish.upperBound
        if upper < original.endIndex, original[upper] == "\n" { upper = original.index(after: upper) }
        var result = original
        result.replaceSubrange(start.lowerBound..<upper, with: block)
        return result == original ? nil : Merge(text: result, updated: true)
    }
}

#if !os(WASI)
extension SetupInstaller {
    /// Adds drip's block to the shell's rc file, as `install(_:)` adds an agent's hooks: never to a
    /// file that is a symlink or read-only, which drip says and prints the block for instead.
    public func install(_ shell: ShellHook.Shell) -> Outcome {
        let path = ShellHook.rcPath(for: shell, environment: environment)
        let snippet = ShellHook.snippet(for: shell)
        func refused(_ problem: String) -> Outcome {
            .refused(reason: "\(display(path)) \(problem), so drip leaves it alone: add this block to it yourself.", snippet: snippet)
        }
        let existing: String?
        if FileManager.default.fileExists(atPath: path) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return refused("cannot be read as text")
            }
            existing = text
        } else {
            existing = nil
        }
        let merge: ShellHook.Merge?
        do {
            merge = try ShellHook.merge(existing, shell: shell)
        } catch let refusal as ShellHook.Refusal {
            return refused(refusal.description)
        } catch {
            return .failed("\(display(path)): \(error)")
        }
        guard let merge else {
            return .done(lines: ["drip's block is already in \(display(path))."], warnings: [])
        }
        if let problem = problem(writing: path) {
            return refused(problem)
        }
        var lines: [String] = []
        do {
            if let backup = try write(merge.text, to: path) {
                lines.append("Backed up the old \((path as NSString).lastPathComponent) to \(display(backup)).")
            }
        } catch {
            return .failed("could not write \(display(path)): \(error.localizedDescription)")
        }
        lines.insert(
            merge.updated ? "Brought drip's block up to date in \(display(path))." : "Added drip's block to \(display(path)).",
            at: 0)
        lines.append("A shell that is open runs it after `exec zsh`; a new one does already.")
        return .done(lines: lines, warnings: [])
    }
}

extension ShellHook {
    /// The card for a command that ended, or nil for none: no GUI session, `DRIP_HOOK=off` or the
    /// orchestrator's variable keep it silent, and so does watching the terminal it ran in, where the
    /// pane and the app are drip's `Front`, whatever `when_focused` says, except `show`, which shows
    /// every card. A terminal that is the frontmost app counts as watched unless tmux or herdr says
    /// the command's own pane is not the one showing.
    public static func card(
        command: String, status: Int32, seconds: Double, flags: CardFlags = CardFlags(),
        in surroundings: AgentHook.Surroundings
    ) throws -> Card? {
        let environment = surroundings.environment
        guard surroundings.hasGUISession, environment[silencedBy].map({ $0.isEmpty }) ?? true,
              try AgentHook.setting(environment: environment) != .off
        else { return nil }
        let resolver = try surroundings.resolver(try surroundings.loadConfig(environment), environment)
        let card = try resolver.resolveRun(command: [command], status: status, seconds: seconds, flags: flags)
        guard resolver.whenFocused != .show else { return card }
        var front = surroundings.front(card)
        guard front.app, front.present(awayAfter: resolver.awayAfter) else { return card }
        if front.pane == nil { front.pane = surroundings.paneShowing(card) }
        return front.pane ?? true ? nil : card
    }
}
#endif
