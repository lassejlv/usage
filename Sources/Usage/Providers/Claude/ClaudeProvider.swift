import Foundation

/// Claude usage provider. Loads OAuth credentials, refreshes the token when stale, fetches the usage
/// endpoint, and maps the response into the shared `UsageMetric` model.
actor ClaudeProvider: UsageProvider {
    nonisolated let info = ProviderInfo(
        id: "claude",
        displayName: "Claude",
        fallbackSymbol: "sparkles"
    )

    private let authStore: ClaudeAuthStore
    private let client: ClaudeUsageClient
    private let ccusage: CcusageClient
    private let now: @Sendable () -> Date

    /// Last computed spend (today / 30-day cost + tokens), served immediately while a fresh value is
    /// fetched in the background. ccusage spawns a subprocess, so we never block a refresh on it.
    private var cachedSpend: SpendSummary?
    private var spendUpdatedAt: Date?
    private var spendInFlight = false
    private static let spendTTL: TimeInterval = 90

    /// Last clean usage, served during a rate-limit window so the card never blanks. Only ever holds a
    /// successful mapping (never a rate-limited snapshot), so the staleness note is never baked in.
    private var lastGoodMetrics: [UsageMetric]?
    private var lastGoodPlan: String?
    /// While `now() < rateLimitedUntil` we skip the live call entirely so we don't keep hammering an
    /// endpoint that's already 429ing us. Driven by the server's Retry-After when present.
    private var rateLimitedUntil: Date?

    private static let fallbackCooldown: TimeInterval = 5 * 60

    init(
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        client: ClaudeUsageClient = ClaudeUsageClient(),
        ccusage: CcusageClient = CcusageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.client = client
        self.ccusage = ccusage
        self.now = now
    }

    func refresh() async -> ProviderSnapshot {
        refreshSpendIfNeeded()
        return await fetchSnapshot().attaching(spend: cachedSpend)
    }

    /// Kick off a background spend refresh when the cache is stale and none is in flight. The result
    /// is cached on the actor and surfaces on the next refresh — never blocking this one.
    private func refreshSpendIfNeeded() {
        if spendInFlight { return }
        if let updatedAt = spendUpdatedAt, now().timeIntervalSince(updatedAt) < Self.spendTTL { return }
        spendInFlight = true
        Task {
            let spend = await ccusage.spend(for: .claude, now: now())
            applySpend(spend)
        }
    }

    private func applySpend(_ spend: SpendSummary?) {
        spendInFlight = false
        // On failure (nil) leave spendUpdatedAt untouched so the next refresh retries, rather than
        // suppressing it for the full TTL (a cold ccusage / unresolved PATH would otherwise stick).
        guard let spend else { return }
        spendUpdatedAt = now()
        guard spend != cachedSpend else { return }
        cachedSpend = spend
        NotificationCenter.default.post(
            name: .providerSpendDidUpdate, object: nil,
            userInfo: [SpendUpdate.idKey: info.id, SpendUpdate.spendKey: spend]
        )
    }

    private func fetchSnapshot() async -> ProviderSnapshot {
        guard var oauth = authStore.load(),
              oauth.accessToken?.isEmpty == false
        else {
            return .error(info, ClaudeAuthError.notLoggedIn.localizedDescription)
        }

        // A credential without the `user:profile` scope (an inference-only login) will 403 on the usage
        // endpoint. Detect it and surface an actionable note instead of hammering the endpoint — the
        // Cost block (from local logs) still attaches, so the card stays useful.
        guard authStore.canFetchLiveUsage(oauth) else {
            return .error(
                info,
                "Logged in for inference only — re-login with Claude Code to show live usage."
            )
        }

        // Inside an active cooldown, skip the network entirely and serve last-good (or a calm badge).
        if let until = rateLimitedUntil {
            if now() < until { return rateLimited(plan: lastGoodPlan, retryAt: until) }
            rateLimitedUntil = nil
        }

        do {
            // Refresh the access token if it's expired (or close to it) and we have a refresh token.
            if authStore.needsRefresh(oauth, now: now()),
               let refreshed = try await client.refresh(oauth, now: now()) {
                oauth = refreshed
                authStore.saveToFile(oauth)
            }

            let response = try await client.fetchUsage(accessToken: oauth.accessToken ?? "")

            // A 401 after the proactive refresh means the token is genuinely dead — try one more refresh.
            if response.statusCode == 401,
               let refreshed = try await client.refresh(oauth, now: now()) {
                oauth = refreshed
                authStore.saveToFile(oauth)
                let retry = try await client.fetchUsage(accessToken: oauth.accessToken ?? "")
                return handle(retry, oauth: oauth)
            }

            return handle(response, oauth: oauth)
        } catch let error as ClaudeAuthError {
            return .error(info, error.localizedDescription)
        } catch {
            return .error(info, "Couldn't reach Claude. Check your connection.")
        }
    }

    // MARK: - Rate limiting

    /// Divert 429s to the cooldown/last-good path; everything else maps normally.
    private func handle(_ response: HTTPResponse, oauth: ClaudeOAuth) -> ProviderSnapshot {
        if response.statusCode == 429 { return enterRateLimit(response, oauth: oauth) }
        return map(response, oauth: oauth)
    }

    /// Start a cooldown (honoring Retry-After) and serve last-good or a calm badge.
    private func enterRateLimit(_ response: HTTPResponse, oauth: ClaudeOAuth) -> ProviderSnapshot {
        let seconds = max(1, retryAfterSeconds(response) ?? Self.fallbackCooldown)
        let until = now().addingTimeInterval(seconds)
        rateLimitedUntil = until
        if lastGoodPlan == nil { lastGoodPlan = plan(oauth) }
        return rateLimited(plan: lastGoodPlan, retryAt: until)
    }

    /// Last-good metrics with a staleness note when we have them; otherwise a friendly badge — never an
    /// error. The note carries the retry time, so the no-data badge isn't repeated as a separate line.
    private func rateLimited(plan: String?, retryAt: Date) -> ProviderSnapshot {
        let mins = max(1, Int((retryAt.timeIntervalSince(now()) / 60).rounded(.up)))
        if let metrics = lastGoodMetrics {
            return .ok(
                info, plan: plan, metrics: metrics, at: now(),
                note: "Live usage rate limited — retry in ~\(mins)m", stale: true
            )
        }
        return .rateLimited(info, plan: plan, note: "Rate limited — retry in ~\(mins)m", at: now())
    }

    /// Parse Retry-After: integer seconds, or an RFC 1123 HTTP-date.
    private func retryAfterSeconds(_ response: HTTPResponse) -> TimeInterval? {
        guard let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else {
            return nil
        }
        if let seconds = Double(raw), seconds.isFinite { return max(0, seconds) }
        if let date = Self.httpDateFormatter.date(from: raw) {
            return max(0, date.timeIntervalSince(now()))
        }
        return nil
    }

    /// Cached so we don't allocate a DateFormatter on every 429 (read-only across the actor's
    /// serialized calls, so sharing one instance is safe).
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    // MARK: - Mapping

    private func map(_ response: HTTPResponse, oauth: ClaudeOAuth) -> ProviderSnapshot {
        guard response.isSuccess else {
            if response.statusCode == 401 {
                return .error(info, ClaudeAuthError.sessionExpired.localizedDescription)
            }
            return .error(info, "Claude returned an error (\(response.statusCode)).")
        }
        guard let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return .error(info, "Couldn't read Claude's response.")
        }

        var metrics: [UsageMetric] = []
        appendWindow(body["five_hour"], label: "Session", windowDuration: 5 * 3600, into: &metrics)
        appendWindow(body["seven_day"], label: "Weekly", windowDuration: 7 * 86400, into: &metrics)
        appendWindow(body["seven_day_sonnet"], label: "Sonnet", windowDuration: 7 * 86400, into: &metrics)
        appendExtraUsage(body["extra_usage"], into: &metrics)

        // Cache only clean successes; the cooldown path never writes here.
        lastGoodMetrics = metrics
        lastGoodPlan = plan(oauth)
        rateLimitedUntil = nil
        return .ok(info, plan: lastGoodPlan, metrics: metrics, at: now())
    }

    private func appendWindow(
        _ value: Any?, label: String, windowDuration: TimeInterval, into metrics: inout [UsageMetric]
    ) {
        guard let object = value as? [String: Any],
              let utilization = number(object["utilization"])
        else {
            return
        }
        metrics.append(UsageMetric(
            label: label,
            used: utilization,
            limit: 100,
            kind: .percent,
            resetsAt: date(object["resets_at"]),
            windowDuration: windowDuration
        ))
    }

    private func appendExtraUsage(_ value: Any?, into metrics: inout [UsageMetric]) {
        guard let object = value as? [String: Any],
              object["is_enabled"] as? Bool == true,
              let usedCents = number(object["used_credits"]),
              let limitCents = number(object["monthly_limit"]), limitCents > 0
        else {
            return
        }
        metrics.append(UsageMetric(
            label: "Extra Usage",
            used: usedCents / 100,
            limit: limitCents / 100,
            kind: .dollars
        ))
    }

    private func plan(_ oauth: ClaudeOAuth) -> String? {
        guard let raw = oauth.subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        let base = raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
        if let tier = oauth.rateLimitTier,
           let match = tier.range(of: #"\d+x"#, options: .regularExpression) {
            return "\(base) \(tier[match])"
        }
        return base
    }

    // MARK: - Parsing helpers

    private func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: double
        case let int as Int: Double(int)
        case let string as String: Double(string)
        default: nil
        }
    }

    private func date(_ value: Any?) -> Date? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
        }
        guard let raw = number(value), raw.isFinite else { return nil }
        // Heuristic: small numbers are seconds, large are milliseconds.
        let seconds = raw < 1e11 ? raw : raw / 1000
        return Date(timeIntervalSince1970: seconds)
    }
}
