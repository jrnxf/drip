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
    /// background process asking an app to activate itself can be refused.
    static func activate(_ bundleIdentifier: String, pane: TerminalPane? = nil, console: Console) {
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
            } else if let pane {
                Terminal.select(pane)
            }
            CardActions.activations.leave()
        }
    }

    /// Waits, briefly, for activations to be handed off, so exiting does not cut them short.
    static func waitForActivations() {
        _ = activations.wait(timeout: .now() + 2)
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
