/// How cards stack at the notch. `chain` (the default) drops each new card from the bottom of the
/// last, `push` drops it from the notch and pushes the others down, and `DRIP_STACK=off` shows one
/// card at a time.
public struct StackSettings: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case chain, push
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

    /// The settings from `DRIP_STACK` and `DRIP_STACK_MAX`, then the config's `stack_max`, then
    /// the defaults. Nil when stacking is off. A config that cannot be read is left out: the drip
    /// that queued the cards already reported it. A `mode` given stacks the cards that way whatever
    /// `DRIP_STACK` says, as `drip demo` does.
    public static func current(
        environment: [String: String], config: Config? = nil, mode: Mode? = nil
    ) -> StackSettings? {
        let value = environment["DRIP_STACK"]?.lowercased() ?? Mode.chain.rawValue
        guard let mode = mode ?? Mode(rawValue: value) else { return nil }
        let config = config ?? (try? ConfigLoader.load(environment: environment))?.config
        let max = environment["DRIP_STACK_MAX"].flatMap(Int.init) ?? config?.stackMax ?? Defaults.stackMax
        return StackSettings(
            mode: mode, max: Swift.min(Swift.max(max, Defaults.stackMaxRange.lowerBound), Defaults.stackMaxRange.upperBound))
    }
}
