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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // A program that hangs never holds drip, or the click, up for long.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

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
    /// answers over ssh, so its commands get longer.
    static func select(_ pane: TerminalPane) {
        if let socket = pane.tmuxSocket, let id = pane.tmuxPane, let found = tmux(pane),
           let client = TerminalPane.client(for: found.session, among: found.clients), client.session != found.session
        {
            _ = output(["tmux", "-S", socket, "switch-client", "-c", client.name, "-t", id])
        }
        for command in pane.selectCommands { _ = output(command, timeout: pane.herdrMachine == nil ? 1 : 5) }
    }

    /// Whether the pane is the one its tmux client or herdr shows; nil when drip cannot tell, as
    /// outside both.
    static func isShowing(_ pane: TerminalPane) -> Bool? {
        if let command = pane.herdrShowingCommand {
            return output(command).flatMap(TerminalPane.isShowing(herdrPane:))
        }
        guard let socket = pane.tmuxSocket, let id = pane.tmuxPane,
              let output = output(["tmux", "-S", socket, "display-message", "-p", "-t", id, TerminalPane.tmuxShowingFormat])
        else { return nil }
        return TerminalPane.isShowing(tmuxDisplay: output)
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
