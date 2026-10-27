#if !os(WASI)
import DripCore
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The terminal a card came from, through the tools its multiplexer or terminal provides: tmux,
/// herdr and WezTerm's command lines, which need no permission.
enum Terminal {
    /// What `arguments`, a program found on `PATH` and its arguments, after any `NAME=value` for its
    /// environment, prints, when it exits 0 within `timeout` seconds; nil otherwise, as when the
    /// program is missing.
    static func output(_ arguments: [String], timeout: Double = 1) -> String? {
        try? run(arguments, timeout: timeout).get()
    }

    /// Why a program `run` ran did not answer: what it wrote to stderr, and how it ended.
    typealias Failure = TimedCommand.Failure

    /// What `arguments`, as `output` takes them, prints, when it exits 0 within `timeout` seconds;
    /// else why not. A program that hangs never holds drip, or the click, up for much longer.
    static func run(_ arguments: [String], timeout: Double = 1) -> Result<String, Failure> {
        TimedCommand.run(arguments, timeout: timeout)
    }

    /// How long herdr on another machine, which answers over ssh, has to answer a click, and to say
    /// whether the agent's pane is in front, which holds its card up meanwhile.
    static let remoteTimeout = 5.0, remoteShowingTimeout = 3.0

    /// The clients attached to the pane's tmux server, and the session the pane is in; nil outside
    /// tmux, or when tmux cannot say.
    private static func tmux(_ pane: TerminalPane) -> (session: String, clients: [TerminalPane.TmuxClient])? {
        guard let socket = pane.tmuxSocket, let id = pane.tmuxPane,
              let session = output(["tmux", "-S", socket, "display-message", "-p", "-t", id, "#{session_name}"])?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !session.isEmpty,
              let list = output(["tmux", "-S", socket, "list-clients", "-F", TerminalPane.tmuxClientFormat])
        else { return nil }
        return (session, TerminalPane.clients(fromTmuxList: list))
    }

    /// Brings the pane forward in its terminal, once the terminal app is in front: in tmux, the
    /// client that shows the pane's session, or else the one used last, switches to it, then its
    /// window and the pane are selected; in WezTerm the pane is activated. herdr on another machine
    /// answers over ssh, so its commands get longer. Says on `console` which command failed.
    static func select(_ pane: TerminalPane, console: Console) {
        if let socket = pane.tmuxSocket, let id = pane.tmuxPane, let found = tmux(pane),
           let client = TerminalPane.client(for: found.session, among: found.clients), client.session != found.session
        {
            _ = output(["tmux", "-S", socket, "switch-client", "-c", client.name, "-t", id])
        }
        for command in pane.selectCommands {
            let result = run(command, timeout: pane.herdrMachine == nil ? 1 : remoteTimeout)
            // The program only: its arguments name sockets and machines.
            DebugLog.record("click", "pane_select", [
                ("program", command.first), ("result", { if case .failure = result { return "failed" } else { return "ok" } }()),
                ("reason", { if case let .failure(failure) = result { return failure.reason } else { return nil } }()),
            ])
            if case let .failure(failure) = result {
                console.click(TerminalPane.selectFailure(command, stderr: failure.stderr, reason: failure.reason))
            }
        }
    }

    /// Whether the pane is the one its tmux client or herdr shows; nil when drip cannot tell, as
    /// outside both, or when herdr on another machine does not answer in time.
    static func isShowing(_ pane: TerminalPane) -> Bool? {
        if let command = pane.herdrShowingCommand {
            return output(command, timeout: pane.herdrMachine == nil ? 1 : remoteShowingTimeout)
                .flatMap(TerminalPane.isShowing(herdrPane:))
        }
        guard let socket = pane.tmuxSocket, let id = pane.tmuxPane,
              let output = output(["tmux", "-S", socket, "display-message", "-p", "-t", id, TerminalPane.tmuxShowingFormat])
        else { return nil }
        return TerminalPane.isShowing(tmuxDisplay: output)
    }

    /// Whether this Mac's herdr shows the machine the pane runs on; unknown when the pane is not on
    /// another machine or herdr cannot say.
    static func machineView(_ pane: TerminalPane) -> MachineView {
        guard let machine = pane.herdrMachine else { return .unknown("not a remote pane") }
        switch run(MachineView.listCommand, timeout: 3) {
        case let .success(output): return MachineView(machineList: output, machine: machine)
        case let .failure(failure): return .unknown(failure.reason)
        }
    }

    #if canImport(AppKit)
    /// The app the pane shows in: the terminal that runs the tmux client showing the pane's session.
    /// tmux keeps the environment of the terminal that started its server, so `__CFBundleIdentifier`
    /// names that terminal even once the session is attached from another. Nil outside tmux, or when
    /// no app runs the client.
    static func app(showing pane: TerminalPane) -> String? {
        guard let found = tmux(pane), let client = TerminalPane.client(for: found.session, among: found.clients)
        else { return nil }
        return app(runningProcess: client.pid)
    }

    /// The bundle identifier of the app that runs `pid`, or one of its parents: a terminal starts a
    /// login, which starts the shell, which starts the tmux client.
    static func app(runningProcess pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: current), let identifier = app.bundleIdentifier {
                return identifier
            }
            guard let parent = parent(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// The parent of the process `pid`; nil when it is gone.
    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
    #endif
}
#endif
