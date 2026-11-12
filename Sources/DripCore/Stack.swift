/// How cards stack at the notch: each new card drops from the bottom of the last.
public struct StackSettings: Equatable, Sendable, Codable {
    /// What the config's `stack` and `DRIP_STACK` take: `chain` (the default) stacks the cards, and
    /// `off` shows one card at a time.
    public enum Choice: String, CaseIterable, Sendable {
        case chain, off

        /// A value drip took before it had one way to stack: `push` now stacks as `chain` does.
        public static let retired = ["push": Choice.chain]
    }

    /// The most cards on screen at once; the rest wait their turn.
    public var max: Int
    /// The pause in seconds after a card is fully in before the next drops in, as the config's
    /// `stack_delay` sets it; nil for the next to drop in once the stack has settled.
    public var delay: Double?

    public init(max: Int, delay: Double? = nil) {
        self.max = max
        self.delay = delay
    }

    /// The settings from `DRIP_STACK`, `DRIP_STACK_MAX` and `DRIP_STACK_DELAY`, then the config's
    /// `stack`, `stack_max` and `stack_delay`, then the defaults. Nil when stacking is off. `CardResolver.stack` gives them from
    /// the config the drip read once, and the drip that shows the cards gets them from it.
    public static func resolved(_ settings: EnvironmentSettings, config: Config) -> StackSettings? {
        guard choice(settings, config: config) != .off else { return nil }
        return StackSettings(max: maxCards(settings, config: config), delay: delay(settings, config: config))
    }

    /// `DRIP_STACK`, then the config's `stack`, then chain.
    public static func choice(_ settings: EnvironmentSettings, config: Config) -> Choice {
        settings.stack ?? config.stack ?? .chain
    }

    /// `DRIP_STACK_MAX`, then the config's `stack_max`, then the default.
    public static func maxCards(_ settings: EnvironmentSettings, config: Config) -> Int {
        settings.stackMax ?? config.stackMax ?? Defaults.stackMax
    }

    /// `DRIP_STACK_DELAY`, then the config's `stack_delay`; nil when neither sets it.
    public static func delay(_ settings: EnvironmentSettings, config: Config) -> Double? {
        settings.stackDelay ?? config.stackDelay
    }
}
