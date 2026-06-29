import Foundation

actor CodexProvider: UsageProvider {
    nonisolated let info = ProviderInfo(
        id: "codex",
        displayName: "Codex",
        fallbackSymbol: "terminal"
    )

    private let authStore: CodexAuthStore
    private let client: CodexUsageClient
    private let now: @Sendable () -> Date

    init(
        authStore: CodexAuthStore = CodexAuthStore(),
        client: CodexUsageClient = CodexUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.client = client
        self.now = now
    }

    func refresh() async -> ProviderSnapshot {
        guard let oauth = authStore.load(),
              oauth.accessToken?.isEmpty == false
        else {
            return .error(info, CodexAuthError.notLoggedIn.localizedDescription)
        }

        do {
            return map(try await client.fetchUsage(oauth: oauth))
        } catch let error as CodexAuthError {
            return .error(info, error.localizedDescription)
        } catch {
            return .error(info, "Couldn't reach Codex. Check your connection.")
        }
    }

    private func map(_ response: HTTPResponse) -> ProviderSnapshot {
        guard response.isSuccess else {
            if response.statusCode == 401 || response.statusCode == 403 {
                return .error(info, "Session expired. Run `codex login` again.")
            }
            return .error(info, "Codex returned an error (\(response.statusCode)).")
        }
        guard let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return .error(info, "Couldn't read Codex's response.")
        }

        let metrics = metrics(from: body, response: response)
        return .ok(info, plan: plan(body["plan_type"]), metrics: metrics, at: now())
    }

    private func metrics(from body: [String: Any], response: HTTPResponse) -> [UsageMetric] {
        var metrics: [UsageMetric] = []

        let rateLimit = body["rate_limit"] as? [String: Any]
        appendWindow(rateLimit?["primary_window"], label: "Session", into: &metrics)
        appendWindow(rateLimit?["secondary_window"], label: "Weekly", into: &metrics)

        if metrics.isEmpty {
            if let used = number(response.header("x-codex-primary-used-percent")) {
                metrics.append(UsageMetric(
                    label: "Session",
                    used: normalizePercent(used),
                    limit: 100,
                    resetsAt: resetDate(rateLimit?["primary_window"] as? [String: Any])
                ))
            }
            if let used = number(response.header("x-codex-secondary-used-percent")) {
                metrics.append(UsageMetric(
                    label: "Weekly",
                    used: normalizePercent(used),
                    limit: 100,
                    resetsAt: resetDate(rateLimit?["secondary_window"] as? [String: Any])
                ))
            }
        }

        if let remaining = readCreditsRemaining(body: body, response: response) {
            metrics.append(UsageMetric(
                label: "Credits",
                used: max(0, remaining),
                limit: max(1, remaining),
                kind: .credits
            ))
        }

        return metrics
    }

    private nonisolated func appendWindow(_ value: Any?, label: String, into metrics: inout [UsageMetric]) {
        guard let object = value as? [String: Any] else { return }

        if let percent = percentUsed(object) {
            metrics.append(UsageMetric(
                label: label,
                used: percent,
                limit: 100,
                kind: .percent,
                resetsAt: resetDate(object)
            ))
            return
        }

        guard let used = number(object["used"])
                ?? number(object["usage"])
                ?? number(object["current_usage"]),
              let limit = number(object["limit"])
                ?? number(object["hard_limit"])
                ?? number(object["max"])
                ?? number(object["total"]),
              limit > 0
        else {
            return
        }

        metrics.append(UsageMetric(
            label: label,
            used: used,
            limit: limit,
            kind: .percent,
            resetsAt: resetDate(object)
        ))
    }

    private nonisolated func percentUsed(_ object: [String: Any]) -> Double? {
        if let percent = number(object["percent_used"])
            ?? number(object["percentage_used"])
            ?? number(object["used_percent"])
            ?? number(object["utilization"]) {
            return normalizePercent(percent)
        }
        if let remaining = number(object["percent_remaining"])
            ?? number(object["remaining_percent"]) {
            return 100 - normalizePercent(remaining)
        }
        return nil
    }

    private nonisolated func normalizePercent(_ value: Double) -> Double {
        let percent = value < 1 ? value * 100 : value
        return min(max(percent, 0), 100)
    }

    private nonisolated func resetDate(_ object: [String: Any]?) -> Date? {
        guard let object else { return nil }
        return date(object["resets_at"])
            ?? date(object["reset_at"])
            ?? date(object["reset_time"])
            ?? date(object["resetsAt"])
            ?? secondsFromNow(object["reset_after_seconds"])
    }

    private nonisolated func readCreditsRemaining(body: [String: Any], response: HTTPResponse) -> Double? {
        if let credits = body["credits"] as? [String: Any] {
            if let balance = number(credits["balance"]) {
                return balance
            }
            if credits["has_credits"] as? Bool == false {
                return 0
            }
        }
        return number(response.header("x-codex-credits-balance"))
    }

    private nonisolated func plan(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        switch raw.lowercased() {
        case "prolite":
            return "Pro 5x"
        case "pro":
            return "Pro 20x"
        default:
            return raw
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    private nonisolated func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: double
        case let int as Int: Double(int)
        case let string as String: Double(string)
        default: nil
        }
    }

    private nonisolated func date(_ value: Any?) -> Date? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
        }
        guard let raw = number(value), raw.isFinite else { return nil }
        let seconds = raw < 1e11 ? raw : raw / 1000
        return Date(timeIntervalSince1970: seconds)
    }

    private nonisolated func secondsFromNow(_ value: Any?) -> Date? {
        guard let seconds = number(value), seconds.isFinite else { return nil }
        return Date().addingTimeInterval(seconds)
    }
}
