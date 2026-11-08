#if canImport(AppKit)
import AppKit
import DripCore

/// What a click on a card does.
enum CardActions {
    /// Set when a card with a button went away without the button being clicked.
    static var missed = false
    /// Set when a question was answered no.
    static var declined = false
    /// The button a question was answered with, set only by a press of it: a card that went any
    /// other way, or never showed, leaves it nil.
    static var pressed: CardAnswer?

    /// Notes how a click went in the debug log: what drip tried to bring forward, and whether macOS
    /// refused. Never a window's title, or what a command printed.
    static func record(_ decision: String, _ fields: [(String, String?)]) {
        DebugLog.record("click", decision, fields)
    }

    /// Activation requests still on their way to Launch Services, and click commands still running.
    private static let activations = DispatchGroup()

    /// What a click anywhere on `card` does: brings its app forward, as a click in the Dock would,
    /// then its tmux pane, and runs its `--on-click` command, with the card on its stdin. Launch
    /// Services brings the app forward, because a background process asking an app to activate
    /// itself can be refused. Says on `console` how each went, macOS refusing too.
    static func click(_ card: Card, console: Console) {
        if let target = card.activate { activate(target, pane: card.pane, console: console) }
        if let onClick = card.onClick { run(onClick, for: card, console: console) }
    }

    /// Brings the app with `bundleIdentifier` forward, then the terminal `pane` in it.
    static func activate(_ bundleIdentifier: String, pane: TerminalPane? = nil, console: Console) {
        record("attempt", [("target", bundleIdentifier), ("pane", pane?.debugName)])
        open(bundleIdentifier, pane: pane, console: console)
    }

    /// Runs `onClick` with `/bin/sh -c`, the click's payload on its stdin, for up to
    /// `OnClick.timeout` seconds. The debug log notes how it ended, never what it printed.
    private static func run(_ onClick: OnClick, for card: Card, console: Console) {
        let payload = onClick.payload(for: card)
        activations.enter()
        DispatchQueue.global().async {
            defer { CardActions.activations.leave() }
            let result = TimedCommand.run(["/bin/sh", "-c", onClick.command], input: payload, timeout: OnClick.timeout)
            switch result {
            case .success:
                record("on_click", [("result", "ok")])
            case let .failure(failure):
                record("on_click", [("result", "failed"), ("reason", failure.reason)])
                let said = failure.stderr.split(whereSeparator: \.isNewline).first.map { String($0.prefix(300)) }
                console.click("the --on-click command failed: \(said ?? failure.reason)")
            }
        }
    }

    /// Brings the app forward through Launch Services, then `pane` in it.
    private static func open(_ bundleIdentifier: String, pane: TerminalPane?, console: Console) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            record("refused", [("target", bundleIdentifier), ("reason", "app_not_found")])
            console.click("cannot find the app \(bundleIdentifier) to bring forward")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        activations.enter()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                let nsError = error as NSError
                record("refused", [("target", bundleIdentifier), ("reason", "open_failed"), ("error", "\(nsError.domain):\(nsError.code)")])
                console.click("cannot bring \(bundleIdentifier) forward: \(error.localizedDescription)")
            } else {
                if let pane { Terminal.select(pane, console: console) }
                report(bundleIdentifier, as: bundleIdentifier, console: console)
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
        let window = hasWindowOnThisSpace(bundleIdentifier)
        if front != bundleIdentifier {
            record("refused", [("target", bundleIdentifier), ("reason", "not_frontmost"), ("frontmost", front ?? "none")])
            console.click("macOS did not bring \(what) forward: \(front ?? "no app") is in front")
        } else if !window {
            record("refused", [("target", bundleIdentifier), ("reason", "no_window_on_space"), ("frontmost", front)])
            console.click("macOS did not bring \(what) forward: it is in front, with no window on this Space")
        } else {
            record("brought", [("target", bundleIdentifier), ("frontmost", front)])
            console.click("brought \(what) forward", failed: false)
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

    /// Waits for activations to be handed off and click commands to end, so exiting does not cut
    /// them short: long enough for an `--on-click` command's timeout, and its grace.
    static func waitForActivations() {
        _ = activations.wait(timeout: .now() + OnClick.timeout + TimedCommand.grace + 1)
    }

    /// Answers a card's buttons: yes runs the action, no is reported through drip's exit status.
    static func answer(_ answer: CardAnswer, to action: CardAction, console: Console) {
        pressed = answer
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
