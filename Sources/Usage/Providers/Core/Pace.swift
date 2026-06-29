import Foundation

/// Burn-rate pacing for a bounded metric — the "Know Before You Run Out" projection. Given how much of
/// a quota is spent and how far through the reset window we are, it projects usage at the current rate
/// to the end of the window and classifies whether you'll finish comfortably, cut it close, or run out
/// early (and if so, roughly when). Pure logic, no UI.
enum Pace {
    enum Status {
        case ahead     // projected to finish with ≥10% of the quota to spare
        case onTrack   // projected to land inside the last 10% — cutting it close
        case behind    // projected to blow past the limit before reset
    }

    struct Result {
        let status: Status
        /// Projected end-of-window usage, in the same unit as `used`/`limit`.
        let projectedUsage: Double
    }

    /// Minimum time into the window before a projection is trustworthy. Set at 10% of the window (5-min
    /// floor): early in a long window a short burst extrapolates to a wild "runs out" false alarm, so we
    /// stay quiet until enough of the period has elapsed for the burn rate to mean something.
    static func minimumElapsed(periodDuration: TimeInterval) -> TimeInterval {
        max(300, periodDuration * 0.1)
    }

    /// Full pace evaluation, or `nil` when there's no signal (window not started, already reset, or too
    /// early for a stable projection).
    static func evaluate(
        used: Double, limit: Double, resetsAt: Date, periodDuration: TimeInterval, now: Date = Date()
    ) -> Result? {
        guard limit > 0, periodDuration > 0 else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-periodDuration))
        guard elapsed >= minimumElapsed(periodDuration: periodDuration), now < resetsAt else { return nil }

        if used <= 0 { return Result(status: .ahead, projectedUsage: 0) }
        let projected = used / elapsed * periodDuration
        if used >= limit { return Result(status: .behind, projectedUsage: projected) }

        let status: Status
        if projected <= limit * 0.9 { status = .ahead }
        else if projected <= limit { status = .onTrack }
        else { status = .behind }
        return Result(status: status, projectedUsage: projected)
    }

    /// Projected seconds until the quota is exhausted, but only when we're `behind` and the run-out
    /// lands before the window resets (otherwise there's nothing to warn about).
    static func secondsToRunOut(
        used: Double, limit: Double, resetsAt: Date, periodDuration: TimeInterval, now: Date = Date()
    ) -> TimeInterval? {
        guard let result = evaluate(used: used, limit: limit, resetsAt: resetsAt,
                                    periodDuration: periodDuration, now: now),
              result.status == .behind else {
            return nil
        }
        let rate = result.projectedUsage / periodDuration
        guard rate > 0 else { return nil }
        let eta = (limit - used) / rate
        let remaining = resetsAt.timeIntervalSince(now)
        guard eta > 0, eta < remaining else { return nil }
        return eta
    }
}
