import Foundation

actor OpenRouterProvider: UsageProvider {
    nonisolated let info = ProviderInfo(
        id: "openrouter", displayName: "OpenRouter",
        fallbackSymbol: "point.3.connected.trianglepath.dotted")

    private let client = OpenRouterUsageClient()
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func refresh() async -> ProviderSnapshot {
        guard
            let key = ProviderHelpers.apiKey(
                configPaths: ["~/.config/usage/openrouter.json", "~/.config/openrouter/key.json"],
                environmentNames: ["OPENROUTER_API_KEY", "OPENROUTER_KEY"]
            )
        else {
            return .error(
                info,
                "No OpenRouter API key. Set OPENROUTER_API_KEY or ~/.config/usage/openrouter.json.")
        }

        async let creditsResponse = try? client.fetchCredits(apiKey: key)
        async let keyResponse = try? client.fetchKey(apiKey: key)
        let (credits, keyMeta) = await (creditsResponse, keyResponse)

        if credits?.statusCode == 401 || credits?.statusCode == 403,
            keyMeta?.statusCode == 401 || keyMeta?.statusCode == 403
        {
            return .error(info, "OpenRouter API key invalid.")
        }

        var metrics: [UsageMetric] = []
        if let credits, credits.isSuccess,
            let data = ProviderHelpers.jsonObject(credits.body)?["data"] as? [String: Any]
        {
            metrics += creditMetrics(data)
        }
        var plan: String?
        if let keyMeta, keyMeta.isSuccess,
            let data = ProviderHelpers.jsonObject(keyMeta.body)?["data"] as? [String: Any]
        {
            let mapped = keyMetrics(data)
            plan = mapped.plan
            metrics += mapped.metrics
        }

        guard !metrics.isEmpty else {
            return .error(info, "OpenRouter usage data unavailable.")
        }
        return .ok(info, plan: plan, metrics: metrics, at: now())
    }

    private nonisolated func creditMetrics(_ data: [String: Any]) -> [UsageMetric] {
        guard let totalUsage = ProviderHelpers.number(data["total_usage"]) else { return [] }
        let used = max(0, totalUsage)
        let totalCredits = max(0, ProviderHelpers.number(data["total_credits"]) ?? 0)
        var metrics: [UsageMetric] = []
        if totalCredits > 0 {
            metrics.append(
                UsageMetric(label: "Credits", used: used, limit: totalCredits, kind: .dollars))
        }
        metrics.append(
            UsageMetric(
                label: "Balance", used: 0, limit: max(0, totalCredits - used), kind: .dollars))
        return metrics
    }

    private nonisolated func keyMetrics(_ data: [String: Any]) -> (
        plan: String?, metrics: [UsageMetric]
    ) {
        var metrics: [UsageMetric] = []
        if let limit = ProviderHelpers.number(data["limit"]), limit > 0 {
            metrics.append(
                UsageMetric(
                    label: "Key Limit",
                    used: max(0, ProviderHelpers.number(data["usage"]) ?? 0),
                    limit: limit,
                    kind: .dollars
                ))
        }
        let plan = (data["is_free_tier"] as? Bool).map { $0 ? "Free tier" : "Pay as you go" }
        return (plan, metrics)
    }
}

struct OpenRouterUsageClient: Sendable {
    static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!
    static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    var http = HTTPClient()

    func fetchCredits(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.creditsURL, apiKey: apiKey)
    }
    func fetchKey(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.keyURL, apiKey: apiKey)
    }

    private func get(_ url: URL, apiKey: String) async throws -> HTTPResponse {
        try await http.send(
            HTTPRequest(
                method: "GET",
                url: url,
                headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"],
                timeout: 15
            ))
    }
}
