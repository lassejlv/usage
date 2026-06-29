import Foundation

/// One of the three quota milestones a user can be alerted about. Each maps to a per-milestone toggle
/// in Settings and is deduped independently within a reset window.
enum PaceMilestone: String, CaseIterable, Hashable, Sendable {
    /// First time remaining drops under 10% for the window.
    case underTenPercent
    /// Pace worsened from healthy → close-to-limit.
    case healthyToClose
    /// Pace worsened from close-to-limit → running-out.
    case closeToRunningOut

    /// Notification title / Settings label.
    var title: String {
        switch self {
        case .underTenPercent: return "Almost Out"
        case .healthyToClose: return "Cutting It Close"
        case .closeToRunningOut: return "Will Run Out"
        }
    }

    /// Plain-language verdict for the notification body.
    var body: String {
        switch self {
        case .underTenPercent: return "Under 10% usage remaining for this window."
        case .healthyToClose: return "Projected to finish close to your limit."
        case .closeToRunningOut: return "Projected to finish before the limit resets."
        }
    }
}

/// The pace-severity bucket a metric is in. Only the three live-pace verdicts carry a comparable
/// severity; a metric with no trustworthy projection (no window data, or too early) is `untracked`.
enum PaceBucket: Hashable, Sendable {
    case untracked
    case healthy     // on course to finish with ≥10% to spare
    case close       // projected inside the last 10%
    case runningOut  // projected to run out before reset
}

/// Per-metric dedup state, persisted across refresh passes so a milestone fires once per reset window.
struct NotificationState: Equatable, Sendable {
    var resetsAt: Date?
    var firedMilestones: Set<PaceMilestone> = []
    var previousBucket: PaceBucket = .untracked
    var wasUnderTenPercent: Bool = false
    /// True once the first real observation has been recorded as the baseline — so an already-bad
    /// metric at launch is recorded without firing; subsequent worsening edges fire.
    var primed: Bool = false
}

/// Which per-milestone toggles are on (the master toggle is applied by the caller).
struct PaceNotificationToggles: Sendable {
    var underTenPercent: Bool
    var healthyToClose: Bool
    var closeToRunningOut: Bool

    func isOn(_ milestone: PaceMilestone) -> Bool {
        switch milestone {
        case .underTenPercent: return underTenPercent
        case .healthyToClose: return healthyToClose
        case .closeToRunningOut: return closeToRunningOut
        }
    }
}

/// Pure milestone logic — no UI, no UserNotifications — so the firing rules stay testable. Ported from
/// openusage's `PaceNotificationLogic`, taking a pre-computed `PaceBucket` instead of a meter state.
enum PaceNotificationLogic {
    struct Transition: Equatable {
        var fire: [PaceMilestone]
        var newState: NotificationState
    }

    /// Decide which milestones to fire this pass, and the state to persist. The returned `newState`
    /// does NOT mark the fired milestones — the caller commits the dedup mark after delivery, so a
    /// failed delivery doesn't consume the edge.
    static func transitions(
        bucket currentBucket: PaceBucket,
        hasData: Bool,
        /// Remaining share of the limit, 0...1.
        remaining fraction: Double,
        resetsAt: Date?,
        previous: NotificationState,
        toggles: PaceNotificationToggles
    ) -> Transition {
        var next = previous

        // New window (a strictly later reset) clears the dedup so milestones can fire again.
        if let resetsAt, previous.resetsAt == nil || resetsAt > (previous.resetsAt ?? .distantPast) {
            next.firedMilestones = []
            next.wasUnderTenPercent = false
            next.previousBucket = .untracked
        }
        next.resetsAt = resetsAt ?? previous.resetsAt

        // No data: skip without disturbing recorded signals.
        if !hasData { return Transition(fire: [], newState: next) }

        // First real observation this launch: record as baseline without firing.
        if !next.primed {
            next.primed = true
            next.previousBucket = currentBucket
            next.wasUnderTenPercent = fraction < 0.10
            next.firedMilestones = []
            return Transition(fire: [], newState: next)
        }

        var fire: [PaceMilestone] = []

        // Pace-verdict worsening edges (only for live-pace states).
        if currentBucket != .untracked {
            let previousSeverity = severity(next.previousBucket)
            let currentSeverity = severity(currentBucket)
            var paceFired = false
            if currentBucket == .close, previousSeverity < severity(.close) {
                if maybeFire(.healthyToClose, into: &fire, state: &next, toggles: toggles) { paceFired = true }
            }
            if currentSeverity >= severity(.runningOut), previousSeverity < severity(.runningOut) {
                if maybeFire(.closeToRunningOut, into: &fire, state: &next, toggles: toggles) { paceFired = true }
            }
            // Improving pace clears the now-irrelevant fired flags so a later worsening re-fires.
            if currentSeverity < previousSeverity {
                if currentSeverity <= severity(.healthy) { next.firedMilestones.remove(.healthyToClose) }
                if currentSeverity <= severity(.close) { next.firedMilestones.remove(.closeToRunningOut) }
            }
            if currentSeverity <= previousSeverity || paceFired {
                next.previousBucket = currentBucket
            }
        }

        // Under-10%-remaining edge, tracked independently of the pace verdict.
        let underNow = fraction < 0.10
        let underCrossed = underNow && !next.wasUnderTenPercent
        var underFired = false
        if underCrossed, maybeFire(.underTenPercent, into: &fire, state: &next, toggles: toggles) {
            underFired = true
        }
        if !underNow {
            next.firedMilestones.remove(.underTenPercent)
        }
        if !underCrossed || underFired {
            next.wasUnderTenPercent = underNow
        }

        return Transition(fire: fire, newState: next)
    }

    @discardableResult
    private static func maybeFire(
        _ milestone: PaceMilestone,
        into fire: inout [PaceMilestone],
        state: inout NotificationState,
        toggles: PaceNotificationToggles
    ) -> Bool {
        guard toggles.isOn(milestone), !state.firedMilestones.contains(milestone) else { return false }
        fire.append(milestone)
        return true
    }

    private static func severity(_ bucket: PaceBucket) -> Int {
        switch bucket {
        case .untracked: return -1
        case .healthy: return 0
        case .close: return 1
        case .runningOut: return 2
        }
    }
}
