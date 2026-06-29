import Foundation

actor CursorProvider: UsageProvider {
    nonisolated let info = ProviderInfo(
        id: "cursor",
        displayName: "Cursor",
        fallbackSymbol: "cursorarrow"
    )

    private let authStore: CursorAuthStore
    private let client: CursorUsageClient
    private let spendClient: CursorSpendClient
    private let now: @Sendable () -> Date

    /// Last computed spend (today / 30-day cost + tokens), served immediately while a fresh value is
    /// fetched in the background from the usage CSV export — so a refresh never blocks on it.
    private var cachedSpend: SpendSummary?
    private var spendUpdatedAt: Date?
    private var spendInFlight = false
    private static let spendTTL: TimeInterval = 90

    init(
        authStore: CursorAuthStore = CursorAuthStore(),
        client: CursorUsageClient = CursorUsageClient(),
        spendClient: CursorSpendClient = CursorSpendClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.client = client
        self.spendClient = spendClient
        self.now = now
    }

    func refresh() async -> ProviderSnapshot {
        guard var state = authStore.load() else {
            return .error(info, CursorAuthError.notLoggedIn.localizedDescription)
        }

        do {
            if authStore.needsRefresh(state.accessToken),
               let refreshToken = state.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
               !refreshToken.isEmpty,
               let refreshed = try await refreshAccessToken(refreshToken) {
                state.accessToken = refreshed
            }

            guard let accessToken = state.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accessToken.isEmpty
            else {
                return .error(info, CursorAuthError.notLoggedIn.localizedDescription)
            }

            refreshSpendIfNeeded(accessToken: accessToken)

            let usageResponse = try await client.fetchUsage(accessToken: accessToken)
            if usageResponse.statusCode == 401 || usageResponse.statusCode == 403 {
                return .error(info, CursorAuthError.sessionExpired.localizedDescription)
            }
            guard usageResponse.isSuccess,
                  let usage = try? JSONSerialization.jsonObject(with: usageResponse.body) as? [String: Any]
            else {
                return .error(info, "Cursor returned an error (\(usageResponse.statusCode)).")
            }

            let planName = await fetchPlanName(accessToken: accessToken)
            let credits = await fetchCredits(accessToken: accessToken)
            return map(usage: usage, planName: planName, credits: credits).attaching(spend: cachedSpend)
        } catch {
            return .error(info, "Couldn't reach Cursor. Check your connection.")
        }
    }

    /// Kick off a background spend refresh (CSV export) when the cache is stale and none is in flight.
    /// The result is cached on the actor and surfaces on the next refresh — never blocking this one.
    private func refreshSpendIfNeeded(accessToken: String) {
        if spendInFlight { return }
        if let updatedAt = spendUpdatedAt, now().timeIntervalSince(updatedAt) < Self.spendTTL { return }
        spendInFlight = true
        Task {
            let spend = await spendClient.spend(accessToken: accessToken, now: now())
            applySpend(spend)
        }
    }

    private func applySpend(_ spend: SpendSummary?) {
        spendInFlight = false
        // On failure (nil) leave spendUpdatedAt untouched so the next refresh retries.
        guard let spend else { return }
        spendUpdatedAt = now()
        guard spend != cachedSpend else { return }
        cachedSpend = spend
        NotificationCenter.default.post(
            name: .providerSpendDidUpdate, object: nil,
            userInfo: [SpendUpdate.idKey: info.id, SpendUpdate.spendKey: spend]
        )
    }

    private func refreshAccessToken(_ refreshToken: String) async throws -> String? {
        let response = try await client.refreshToken(refreshToken)
        guard response.isSuccess,
              let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              body["shouldLogout"] as? Bool != true
        else {
            return nil
        }
        return (body["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchPlanName(accessToken: String) async -> String? {
        guard let response = try? await client.fetchPlan(accessToken: accessToken),
              response.isSuccess,
              let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let planInfo = body["planInfo"] as? [String: Any],
              let planName = planInfo["planName"] as? String
        else {
            return nil
        }
        return planName
    }

    private func fetchCredits(accessToken: String) async -> [String: Any]? {
        guard let response = try? await client.fetchCredits(accessToken: accessToken),
              response.isSuccess,
              let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else {
            return nil
        }
        return body
    }

    private func map(usage: [String: Any], planName: String?, credits: [String: Any]?) -> ProviderSnapshot {
        guard usage["enabled"] as? Bool != false,
              let planUsage = usage["planUsage"] as? [String: Any]
        else {
            return .error(info, "No active Cursor subscription.")
        }

        var metrics: [UsageMetric] = []
        appendCredits(credits, into: &metrics)

        let cycle = billingCycle(from: usage)
        let cycleWindow: TimeInterval? = cycle.periodDurationMs > 0 ? Double(cycle.periodDurationMs) / 1000 : nil
        let totalSpend = number(planUsage["totalSpend"])
        let planLimit = number(planUsage["limit"])
        let planRemaining = number(planUsage["remaining"])
        let planUsedCents = totalSpend ?? ((planLimit ?? 0) - (planRemaining ?? 0))
        var totalPercent = number(planUsage["totalPercentUsed"])
        if totalPercent == nil, let planLimit, planLimit > 0 {
            totalPercent = planUsedCents / planLimit * 100
        }

        if let totalPercent {
            metrics.append(UsageMetric(
                label: "Total Usage",
                used: normalizePercent(totalPercent),
                limit: 100,
                resetsAt: cycle.resetsAt,
                windowDuration: cycleWindow
            ))
        }

        if let autoPercent = number(planUsage["autoPercentUsed"]) {
            metrics.append(UsageMetric(
                label: "Auto Usage",
                used: normalizePercent(autoPercent),
                limit: 100,
                resetsAt: cycle.resetsAt,
                windowDuration: cycleWindow
            ))
        }

        if let apiPercent = number(planUsage["apiPercentUsed"]) {
            metrics.append(UsageMetric(
                label: "API Usage",
                used: normalizePercent(apiPercent),
                limit: 100,
                resetsAt: cycle.resetsAt,
                windowDuration: cycleWindow
            ))
        }

        if let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any] {
            appendOnDemand(spendLimitUsage, into: &metrics)
        }

        return .ok(info, plan: planLabel(planName), metrics: metrics, at: now())
    }

    private nonisolated func appendCredits(_ credits: [String: Any]?, into metrics: inout [UsageMetric]) {
        guard credits?["hasCreditGrants"] as? Bool == true,
              let totalCents = number(credits?["totalCents"]),
              totalCents > 0
        else {
            return
        }
        let usedCents = number(credits?["usedCents"]) ?? 0
        metrics.append(UsageMetric(
            label: "Credits",
            used: centsToDollars(max(0, totalCents - usedCents)),
            limit: centsToDollars(totalCents),
            kind: .dollars
        ))
    }

    private nonisolated func appendOnDemand(_ spendLimitUsage: [String: Any], into metrics: inout [UsageMetric]) {
        let limit = number(spendLimitUsage["individualLimit"])
            ?? number(spendLimitUsage["pooledLimit"])
            ?? 0
        let remaining = number(spendLimitUsage["individualRemaining"])
            ?? number(spendLimitUsage["pooledRemaining"])
            ?? 0
        let reported = [
            number(spendLimitUsage["individualUsed"]),
            number(spendLimitUsage["pooledUsed"]),
            number(spendLimitUsage["totalSpend"]),
        ].compactMap { $0 }
        let spent = reported.first(where: { $0 > 0 }) ?? max(0, limit - remaining)
        guard limit > 0 || spent > 0 else { return }

        metrics.append(UsageMetric(
            label: "On-demand",
            used: centsToDollars(spent),
            limit: centsToDollars(max(limit, spent)),
            kind: .dollars
        ))
    }

    private nonisolated func billingCycle(from usage: [String: Any]) -> (resetsAt: Date?, periodDurationMs: Int) {
        let start = number(usage["billingCycleStart"])
        let end = number(usage["billingCycleEnd"])
        guard let start, let end, end > start else {
            return (end.map { Date(timeIntervalSince1970: $0 / 1000) }, 30 * 24 * 60 * 60 * 1000)
        }
        return (Date(timeIntervalSince1970: end / 1000), Int(end - start))
    }

    private nonisolated func normalizePercent(_ value: Double) -> Double {
        let percent = value < 1 ? value * 100 : value
        return min(max(percent, 0), 100)
    }

    private nonisolated func centsToDollars(_ value: Double) -> Double {
        value / 100
    }

    private nonisolated func planLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: \.isWhitespace)
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private nonisolated func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: double
        case let int as Int: Double(int)
        case let string as String: Double(string)
        default: nil
        }
    }
}
