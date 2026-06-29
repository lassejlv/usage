import Foundation

actor ZAIProvider: UsageProvider {
    nonisolated let info = ProviderInfo(id: "zai", displayName: "Z.ai", fallbackSymbol: "sparkles")

    private let client = ZAIUsageClient()
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func refresh() async -> ProviderSnapshot {
        guard
            let key = ProviderHelpers.apiKey(
                configPaths: ["~/.config/usage/zai.json", "~/.config/zai/key.json"],
                environmentNames: ["ZAI_API_KEY", "GLM_API_KEY"]
            )
        else {
            return .error(info, "No Z.ai API key. Set ZAI_API_KEY or ~/.config/usage/zai.json.")
        }

        do {
            let quota = try await client.fetchQuota(apiKey: key)
            if quota.statusCode == 401 || quota.statusCode == 403 {
                return .error(info, "Z.ai API key invalid.")
            }
            guard quota.isSuccess else {
                return .error(info, "Z.ai returned an error (\(quota.statusCode)).")
            }
            if isNoCodingPlan(quota.body) {
                return .error(info, "No active GLM Coding Plan.")
            }
            let subscription = try? await client.fetchSubscription(apiKey: key)
            return .ok(
                info, plan: planName(subscription?.body), metrics: metrics(from: quota.body),
                at: now())
        } catch {
            return .error(info, "Couldn't reach Z.ai. Check your connection.")
        }
    }

    private nonisolated func isNoCodingPlan(_ data: Data) -> Bool {
        guard let root = ProviderHelpers.jsonObject(data), root["success"] as? Bool == false else {
            return false
        }
        return ((root["msg"] as? String) ?? "").lowercased().contains("coding plan")
    }

    private nonisolated func metrics(from data: Data) -> [UsageMetric] {
        guard let root = ProviderHelpers.jsonObject(data) else { return [] }
        let container = root["data"] as? [String: Any] ?? root
        guard let limits = container["limits"] as? [[String: Any]] else { return [] }

        var metrics: [UsageMetric] = []
        for entry in limits
        where (entry["type"] as? String) == "TOKENS_LIMIT"
            || (entry["name"] as? String) == "TOKENS_LIMIT"
        {
            guard let period = periodMs(entry) else { continue }
            let label = period < 24 * 60 * 60 * 1000 ? "Session" : "Weekly"
            metrics.append(
                UsageMetric(
                    label: label,
                    used: ProviderHelpers.clampPercent(
                        ProviderHelpers.number(entry["percentage"]) ?? 0),
                    limit: 100,
                    resetsAt: ProviderHelpers.isoDate(entry["nextResetTime"])
                ))
        }
        if let web = limits.first(where: {
            ($0["type"] as? String) == "TIME_LIMIT" || ($0["name"] as? String) == "TIME_LIMIT"
        }) {
            let used = max(0, ProviderHelpers.number(web["currentValue"]) ?? 0)
            let limit = max(0, ProviderHelpers.number(web["usage"]) ?? 0)
            if limit > 0 {
                metrics.append(
                    UsageMetric(
                        label: "Web Searches",
                        used: used,
                        limit: limit,
                        kind: .count("searches"),
                        resetsAt: ProviderHelpers.isoDate(web["nextResetTime"])
                    ))
            }
        }
        return metrics
    }

    private nonisolated func periodMs(_ entry: [String: Any]) -> Double? {
        guard let unit = ProviderHelpers.number(entry["unit"]),
            let number = ProviderHelpers.number(entry["number"])
        else {
            return nil
        }
        let unitMs: Double
        switch Int(unit) {
        case 3: unitMs = 60 * 60 * 1000
        case 4: unitMs = 24 * 60 * 60 * 1000
        case 5: unitMs = 30 * 24 * 60 * 60 * 1000
        case 6: unitMs = 7 * 24 * 60 * 60 * 1000
        default: return nil
        }
        return unitMs * number
    }

    private nonisolated func planName(_ data: Data?) -> String? {
        guard let data,
            let root = ProviderHelpers.jsonObject(data),
            let list = root["data"] as? [[String: Any]],
            let first = list.first,
            let name = first["productName"] as? String
        else {
            return nil
        }
        return name
    }
}

struct ZAIUsageClient: Sendable {
    static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!
    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    var http = HTTPClient()

    func fetchSubscription(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.subscriptionURL, apiKey: apiKey)
    }

    func fetchQuota(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.quotaURL, apiKey: apiKey)
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
