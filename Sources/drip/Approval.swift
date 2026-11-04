#if canImport(AppKit)
import DripCore
import Foundation

/// Keeps the drip of a permission card with Allow and Deny in step with its agent while the card
/// waits: the card goes when the agent took its answer from the terminal, when the hook's time runs
/// short, or, for an agent that holds its own prompt until the hook returns, when you go to its
/// terminal. A card that goes unclicked prints nothing, which leaves the answer to the terminal.
final class ApprovalWatch {
    /// How long the hook waits in all, a card queued behind others included, before it gives up:
    /// past the card's own `Defaults.approveWait`, still inside the agent's ten-minute hook timeout.
    static let deadline = Defaults.approveWait + 30
    /// How long a drip told to stop gives its card to go, so a stack hands on what it holds, before it
    /// exits anyway: inside the second and a half Claude Code waits before SIGKILL.
    static let grace = 1.0

    private let card: Card
    private let agent: AgentHook.Agent
    private let display: CardDisplay
    private let queue = DispatchQueue(label: "drip.approval")
    private var terminated: DispatchSourceSignal?
    private var looking: Timer?
    private var arrival = TerminalArrival()

    init(card: Card, agent: AgentHook.Agent, display: CardDisplay) {
        self.card = card
        self.agent = agent
        self.display = display
    }

    func start() {
        // Claude Code ends the hook with SIGTERM once you answer in its terminal. The main thread may
        // be waiting for the card's turn, so the signal and the deadline are watched on a queue.
        signal(SIGTERM, SIG_IGN)
        let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        terminated.setEventHandler { [weak self] in self?.giveUp() }
        terminated.resume()
        self.terminated = terminated
        queue.asyncAfter(deadline: .now() + Self.deadline) { [weak self] in self?.giveUp() }
        guard agent.holdsPromptForHook else { return }
        let looking = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.look() }
        RunLoop.main.add(looking, forMode: .common)
        self.looking = looking
    }

    /// Takes the card away, and exits with nothing printed should it not have gone in `grace`.
    private func giveUp() {
        dismiss()
        queue.asyncAfter(deadline: .now() + Self.grace) { _exit(ExitStatus.shown) }
    }

    /// Takes the card away when the agent's terminal came to the front: its prompt shows only once
    /// the hook returns.
    private func look() {
        var front = display.front(of: card)
        if front.pane == nil, front.app { front.pane = display.paneShowing(card) }
        guard arrival.arrived(front) else { return }
        looking?.invalidate()
        dismiss()
    }

    private func dismiss() {
        guard let id = card.id else { return }
        try? DismissRequests(environment: ProcessInfo.processInfo.environment).request(id: id)
    }
}
#endif
