#if canImport(AppKit)
import AppKit
import DripCore

/// What a click on a card does.
enum CardActions {
    /// Set when a card with a button went away without the button being clicked.
    static var missed = false
    /// Set when a question was answered no.
    static var declined = false

    /// Activation requests still on their way to Launch Services.
    private static let activations = DispatchGroup()

    /// Brings the app with `bundleIdentifier` forward, as a click in the Dock would, then the
    /// terminal `pane` in it, when the card names one. Launch Services does it, because a
    /// background process asking an app to activate itself can be refused. For herdr on another
    /// machine in Ghostty, Ghostty itself first brings forward the terminal that shows herdr, on
    /// whichever Space it is. Says on `console` how each attempt went, macOS refusing it too.
    static func activate(_ bundleIdentifier: String, pane: TerminalPane? = nil, console: Console) {
        guard bundleIdentifier == TerminalPane.ghostty, let pane,
              let script = pane.ghosttyRaiseScript(localHost: hostName)
        else {
            open(bundleIdentifier, pane: pane, console: console)
            return
        }
        // Ghostty activates itself only when it is not the active app already, and only activating
        // switches to the Space its terminal is on: when its terminals are all on another Space, drip
        // takes the activation first, so Ghostty's own takes it back there.
        let yielded = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
            && !hasWindowOnThisSpace(bundleIdentifier)
        if yielded { NSApp.activate(ignoringOtherApps: true) }
        activations.enter()
        DispatchQueue.global().async {
            defer { CardActions.activations.leave() }
            if yielded { Thread.sleep(forTimeInterval: 0.1) }
            switch Terminal.run(["osascript", "-e", script], timeout: 5) {
            case let .success(title) where !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                report(bundleIdentifier, as: "Ghostty's \(title.trimmingCharacters(in: .whitespacesAndNewlines))", console: console)
                Terminal.select(pane, console: console)
                return
            case .success:
                console.error("no Ghostty terminal shows herdr on \(pane.hostName ?? "the machine") or this Mac; bringing Ghostty forward")
            case let .failure(failure):
                let said = failure.stderr.split(whereSeparator: \.isNewline).first.map(String.init)
                console.error("cannot bring Ghostty's herdr terminal forward: \(said ?? failure.reason)")
            }
            open(bundleIdentifier, pane: pane, console: console)
        }
    }

    /// This Mac's name, as herdr titles a terminal that shows it: `gethostname`, which, unlike
    /// `ProcessInfo.hostName`, never waits on the network.
    private static var hostName: String? {
        var name = [CChar](repeating: 0, count: 256)
        guard gethostname(&name, name.count) == 0 else { return nil }
        let text = String(cString: name)
        return text.isEmpty ? nil : text
    }

    /// Brings the app forward through Launch Services, then `pane` in it.
    private static func open(_ bundleIdentifier: String, pane: TerminalPane?, console: Console) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            console.error("cannot find the app \(bundleIdentifier) to bring forward")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        activations.enter()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                console.error("cannot bring \(bundleIdentifier) forward: \(error.localizedDescription)")
            } else {
                report(bundleIdentifier, as: bundleIdentifier, console: console)
                if let pane { Terminal.select(pane, console: console) }
            }
            CardActions.activations.leave()
        }
    }

    /// Says whether `bundleIdentifier`, brought forward as `what`, is the frontmost app with a
    /// window on the Space on screen a moment later: macOS can refuse to activate an app for a
    /// process in the background without saying so, and an app already active stays on its Space.
    private static func report(_ bundleIdentifier: String, as what: String, console: Console) {
        Thread.sleep(forTimeInterval: 0.5)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front != bundleIdentifier {
            console.error("macOS did not bring \(what) forward: \(front ?? "no app") is in front")
        } else if !hasWindowOnThisSpace(bundleIdentifier) {
            console.error("macOS did not bring \(what) forward: it is in front, with no window on this Space")
        } else {
            console.error("brought \(what) forward")
        }
    }

    /// Whether the app with `bundleIdentifier` has a window of the normal level on the Space on
    /// screen, as the window list tells without the Screen Recording permission.
    private static func hasWindowOnThisSpace(_ bundleIdentifier: String) -> Bool {
        let apps = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(\.processIdentifier))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return false }
        return windows.contains { window in
            (window[kCGWindowLayer as String] as? Int) == 0
                && (window[kCGWindowOwnerPID as String] as? Int).map { apps.contains(pid_t($0)) } == true
        }
    }

    /// Waits, briefly, for activations to be handed off, so exiting does not cut them short: long
    /// enough for herdr on another machine to answer over ssh.
    static func waitForActivations() {
        _ = activations.wait(timeout: .now() + 12)
    }

    /// Answers a card's buttons: yes runs the action, no is reported through drip's exit status.
    static func answer(_ answer: CardAnswer, to action: CardAction, console: Console) {
        switch answer {
        case .yes: perform(action, console: console)
        case .no: declined = true
        }
    }

    static func perform(_ action: CardAction, console: Console) {
        guard let target = action.open else { return }
        let url = target.contains("://") ? URL(string: target) : URL(fileURLWithPath: (target as NSString)
            .expandingTildeInPath)
        guard let url, NSWorkspace.shared.open(url) else {
            console.error("cannot open \(target)")
            return
        }
    }
}
#endif
