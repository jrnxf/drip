/// How cards stack at the notch. `chain` (the default) drops each new card from the bottom of the
/// last, `push` drops it from the notch and pushes the others down, and `off` shows one card at a
/// time.
public struct StackSettings: Equatable, Sendable, Codable {
    public enum Mode: String, CaseIterable, Sendable, Codable {
        case chain, push
    }

    /// What the config's `stack` and `DRIP_STACK` take: a way to stack, or off.
    public enum Choice: String, CaseIterable, Sendable {
        case chain, push, off

        /// The way to stack; nil for off.
        public var mode: Mode? {
            Mode(rawValue: rawValue)
        }
    }

    public var mode: Mode
    /// The most cards on screen at once; the rest wait their turn.
    public var max: Int
    /// How long each card waits after the one before it dropped in, in order, at the least; cards
    /// past the end wait no longer than the stack needs. `drip demo` holds its last card back.
    public var pauses: [Double]

    public init(mode: Mode, max: Int, pauses: [Double] = []) {
        self.mode = mode
        self.max = max
        self.pauses = pauses
    }

    /// The settings from `DRIP_STACK` and `DRIP_STACK_MAX`, then the config's `stack` and
    /// `stack_max`, then the defaults. Nil when stacking is off. A config or an environment that
    /// cannot be read is left out: the drip that queued the cards already reported it. A `mode`
    /// given stacks the cards that way whatever the settings say, as `drip demo` does.
    public static func current(
        environment: [String: String], config: Config? = nil, mode: Mode? = nil
    ) -> StackSettings? {
        let settings = (try? EnvironmentSettings(environment: environment)) ?? EnvironmentSettings()
        let config = config ?? (try? ConfigLoader.load(environment: environment))?.config
        guard let mode = mode ?? (settings.stack ?? config?.stack ?? .chain).mode else { return nil }
        return StackSettings(mode: mode, max: settings.stackMax ?? config?.stackMax ?? Defaults.stackMax)
    }
}
