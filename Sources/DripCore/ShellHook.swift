#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// The card for a command a zsh shell ran long, without `drip run` in front of it. The hook is the
/// block in the `zsh-slow-commands` recipe: shell code in `~/.zshrc` that notes when each command
/// starts, and when the prompt comes back compares the time with a threshold in the shell itself, so
/// a fast command never starts a drip. Only a slow one does, through `drip __finished`, which shows
/// the card unless you are watching that terminal.
public enum ShellHook {}

#if !os(WASI)
extension ShellHook {
    /// The card for a command that ended, or nil for none: no GUI session or `DRIP_HOOK=off` keep it
    /// silent, and so does watching the terminal it ran in, where the
    /// pane and the app are drip's `Front`, whatever `when_focused` says, except `show`, which shows
    /// every card. A terminal that is the frontmost app counts as watched unless tmux says
    /// the command's own pane is not the one showing.
    public static func card(
        command: String, status: Int32, seconds: Double, flags: CardFlags = CardFlags(),
        in surroundings: AgentHook.Surroundings
    ) throws -> Card? {
        let environment = surroundings.environment
        guard surroundings.hasGUISession,
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
