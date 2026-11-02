import Foundation

/// Retry pacing for sources whose enqueue keeps failing, such as while the store refuses every
/// capture. Without it a failing source is retried on every pass and records a gap each time.
/// The delay doubles from the source's normal cadence up to `maximumDelay`, short enough that
/// collection resumes promptly once the cause clears. The gap is recorded when a failure starts
/// and then once per `gapInterval`, so a long outage stays in the coverage timeline on every day
/// it spans without writing a gap per pass.
struct DeliveryBackoff {
    static let maximumDelay: TimeInterval = 30
    static let gapInterval: TimeInterval = 300

    private struct State {
        var failures: Int
        var retryAt: Date
        var gapAt: Date
    }
    /// Bounded by the sources being polled; an entry exists only while its source is failing.
    private var states: [String: State] = [:]

    static func delay(base: TimeInterval, failures: Int) -> TimeInterval {
        // A source already slower than the cap keeps its own cadence.
        min(base * pow(2, Double(min(max(failures, 1) - 1, 16))), max(base, maximumDelay))
    }

    func isWaiting(_ key: String, at date: Date) -> Bool {
        guard let state = states[key] else { return false }
        return date < state.retryAt
    }

    /// Counts a failed attempt and returns whether its gap should be recorded now.
    mutating func recordFailure(_ key: String, base: TimeInterval, at date: Date) -> Bool {
        var state = states[key] ?? State(failures: 0, retryAt: date, gapAt: .distantPast)
        state.failures += 1
        state.retryAt = date.addingTimeInterval(Self.delay(base: base, failures: state.failures))
        let report = date.timeIntervalSince(state.gapAt) >= Self.gapInterval
        if report { state.gapAt = date }
        states[key] = state
        return report
    }

    mutating func recordSuccess(_ key: String) { states.removeValue(forKey: key) }
}
