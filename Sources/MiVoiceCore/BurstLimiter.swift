import Foundation

/// Sliding-window limiter used as a circuit breaker around configuration
/// attempts. It records each attempt and reports when the number of attempts
/// inside `window` exceeds `limit`.
public struct BurstLimiter {
    public let window: TimeInterval
    public let limit: Int
    private var attempts: [TimeInterval] = []

    public init(window: TimeInterval, limit: Int) {
        self.window = window
        self.limit = max(1, limit)
    }

    /// Records an attempt at `now` and returns true when the burst limit has
    /// been exceeded. The offending attempt is included in the window.
    public mutating func shouldBlock(at now: TimeInterval) -> Bool {
        attempts.removeAll { now - $0 >= window }
        attempts.append(now)
        return attempts.count > limit
    }

    public mutating func reset() {
        attempts.removeAll()
    }

    public var count: Int { attempts.count }
}
