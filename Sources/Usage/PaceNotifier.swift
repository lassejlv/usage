import Foundation
import UserNotifications

/// The proactive "Know Before You Run Out" layer: after each refresh it evaluates every windowed meter
/// against the pace milestones and posts a macOS notification when one crosses a worsening edge — once
/// per reset window. Holds the per-metric dedup state for the session (re-primed each launch, so an
/// already-bad quota at startup is recorded as the baseline rather than alerting immediately).
@MainActor
final class PaceNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var states: [String: NotificationState] = [:]
    private var authorized = false

    func configure(enabled: Bool) {
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorization(requestIfNeeded: enabled)
    }

    /// Called when the master toggle flips on — prompts for permission the first time.
    func setEnabled(_ enabled: Bool) {
        guard enabled else { return }
        refreshAuthorization(requestIfNeeded: true)
    }

    private func refreshAuthorization(requestIfNeeded: Bool) {
        // Pull the Sendable status out of the (non-Sendable) settings before hopping to the main actor.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                self.applyAuthorization(status: status, requestIfNeeded: requestIfNeeded)
            }
        }
    }

    private func applyAuthorization(status: UNAuthorizationStatus, requestIfNeeded: Bool) {
        switch status {
        case .authorized, .provisional:
            authorized = true
        case .notDetermined where requestIfNeeded:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Task { @MainActor in self.authorized = granted }
            }
        default:
            authorized = false
        }
    }

    func evaluate(snapshots: [ProviderSnapshot], settings: ProviderSettingsStore, now: Date = Date()) {
        guard settings.notificationsEnabled, authorized else { return }
        let toggles = PaceNotificationToggles(
            underTenPercent: settings.notifyAlmostOut,
            healthyToClose: settings.notifyCuttingClose,
            closeToRunningOut: settings.notifyWillRunOut
        )

        for snapshot in snapshots {
            guard case .ok = snapshot.state else { continue }
            for metric in snapshot.metrics where isTrackable(metric) {
                let key = "\(snapshot.provider.id)|\(metric.label)"
                let transition = PaceNotificationLogic.transitions(
                    bucket: paceBucket(metric, now: now),
                    hasData: true,
                    remaining: metric.remainingFraction,
                    resetsAt: metric.resetsAt,
                    previous: states[key] ?? NotificationState(),
                    toggles: toggles
                )
                states[key] = transition.newState
                for milestone in transition.fire {
                    deliver(milestone, provider: snapshot.provider, metric: metric)
                    states[key]?.firedMilestones.insert(milestone)
                }
            }
        }
    }

    /// Needs a reset window to dedup against; credits have no schedule, so they're not tracked.
    private func isTrackable(_ metric: UsageMetric) -> Bool {
        guard metric.resetsAt != nil else { return false }
        if case .credits = metric.kind { return false }
        return true
    }

    private func paceBucket(_ metric: UsageMetric, now: Date) -> PaceBucket {
        guard let resetsAt = metric.resetsAt, let window = metric.windowDuration,
              let result = Pace.evaluate(
                used: metric.used, limit: metric.limit, resetsAt: resetsAt,
                periodDuration: window, now: now)
        else {
            return .untracked
        }
        switch result.status {
        case .ahead: return .healthy
        case .onTrack: return .close
        case .behind: return .runningOut
        }
    }

    private func deliver(_ milestone: PaceMilestone, provider: ProviderInfo, metric: UsageMetric) {
        let content = UNMutableNotificationContent()
        content.title = milestone.title
        content.subtitle = "\(provider.displayName) · \(metric.label)"
        content.body = milestone.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(provider.id)-\(metric.label)-\(milestone.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Present banners even though we're a menu-bar accessory (no normal foreground window).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
