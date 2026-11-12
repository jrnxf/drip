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
    /// The seconds from one card dropping in to the next, as the config's `stack_delay` sets it; nil
    /// for the next to drop in once the stack has settled.
    public var delay: Double?

    public init(mode: Mode, max: Int, delay: Double? = nil) {
        self.mode = mode
        self.max = max
        self.delay = delay
    }

    /// The settings from `DRIP_STACK`, `DRIP_STACK_MAX` and `DRIP_STACK_DELAY`, then the config's
    /// `stack`, `stack_max` and `stack_delay`, then the defaults. Nil when stacking is off. `CardResolver.stack` gives them from
    /// the config the drip read once, and the drip that shows the cards gets them from it.
    public static func resolved(_ settings: EnvironmentSettings, config: Config) -> StackSettings? {
        guard let mode = choice(settings, config: config).mode else { return nil }
        return StackSettings(mode: mode, max: maxCards(settings, config: config), delay: delay(settings, config: config))
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
