#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif

/// A damped spring described the way Apple's APIs describe one: how long it takes to look settled and
/// how much it bounces. The same parameters as `CASpringAnimation(perceptualDuration:bounce:)`.
public struct Spring: Equatable, Sendable {
    /// Seconds until it looks settled.
    public var duration: Double
    /// 0 never overshoots; higher values overshoot more. Below 1.
    public var bounce: Double

    public init(duration: Double, bounce: Double = 0) {
        precondition(duration > 0, "a spring needs a positive duration")
        precondition((0..<1).contains(bounce), "bounce must be at least 0 and below 1")
        self.duration = duration
        self.bounce = bounce
    }

    /// For a mass of 1, as `CASpringAnimation.stiffness` takes it.
    public var stiffness: Double { pow(2 * .pi / duration, 2) }
    /// For a mass of 1, as `CASpringAnimation.damping` takes it.
    public var damping: Double { 4 * .pi * (1 - bounce) / duration }

    /// Progress from 0 towards 1, `time` seconds after the spring starts. Above 1 while it overshoots.
    public func progress(at time: Double) -> Double {
        guard time > 0 else { return 0 }
        let natural = 2 * .pi / duration
        let ratio = 1 - bounce
        if ratio < 1 {
            let damped = natural * (1 - ratio * ratio).squareRoot()
            let decay = exp(-ratio * natural * time)
            return 1 - decay * (cos(damped * time) + ratio * natural / damped * sin(damped * time))
        }
        return 1 - exp(-natural * time) * (1 + natural * time)
    }

    /// Seconds after which the spring stays within 0.1 % of its target.
    public var settlingTime: Double {
        let step = 0.001
        var last = 0.0
        var time = step
        while time < 4 * duration + 1 {
            if abs(1 - progress(at: time)) > 0.001 { last = time }
            time += step
        }
        return last + step
    }
}

/// A value that springs towards each new target. A new target adds a spring on top of the ones still
/// running instead of restarting, so the value keeps its velocity through an interruption.
public struct SpringValue: Equatable, Sendable {
    private struct Part: Equatable, Sendable {
        var change: Double
        var spring: Spring
        var start: Double
        var settled: Double
    }

    private var base: Double
    private var parts: [Part] = []

    public init(_ value: Double) {
        base = value
    }

    /// Where the value ends up once every spring has settled.
    public var target: Double {
        parts.reduce(base) { $0 + $1.change }
    }

    /// When the last spring settles; nil while there is none.
    public var end: Double? {
        parts.map { $0.start + $0.settled }.max()
    }

    /// Springs from wherever the value is heading towards `target`, starting at `time`.
    public mutating func animate(to target: Double, with spring: Spring, at time: Double) {
        parts.append(Part(change: target - self.target, spring: spring, start: time, settled: spring.settlingTime))
    }

    /// Jumps to `value` with no motion.
    public mutating func jump(to value: Double) {
        base = value
        parts = []
    }

    public func value(at time: Double) -> Double {
        parts.reduce(base) { $0 + $1.change * $1.spring.progress(at: time - $1.start) }
    }
}
