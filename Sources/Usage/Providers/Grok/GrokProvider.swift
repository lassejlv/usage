import Foundation

private struct GrokAuthEntry: Decodable, Hashable, Sendable {
    var key: String?
    var refreshToken: String?
    var refresh: String?
    var expiresAt: String?
    var expires: String?

    enum CodingKeys: String, CodingKey {
        case key
        case refreshToken = "refresh_token"
        case refresh
        case expiresAt = "expires_at"
        case expires
    }
}

actor GrokProvider: UsageProvider {
    nonisolated let info = ProviderInfo(id: "grok", displayName: "Grok", fallbackSymbol: "xmark")

    private let client = GrokUsageClient()
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func refresh() async -> ProviderSnapshot {
        guard let token = loadAccessToken() else {
            return .error(info, "Grok not logged in. Run `grok login`.")
        }
        do {
            let billing = try await client.fetchBilling(accessToken: token)
            if billing.statusCode == 401 || billing.statusCode == 403 {
                return .error(info, "Grok auth expired. Run `grok login` again.")
            }
            guard billing.isSuccess else { return .error(info, "Grok billing failed (\(billing.statusCode)).") }
            let plan = (try? await client.fetchSettings(accessToken: token)).flatMap(planName)
            return mapBilling(billing.body, plan: plan)
        } catch {
            return .error(info, "Couldn't reach Grok. Check your connection.")
        }
    }

    private nonisolated func loadAccessToken() -> String? {
        guard let text = ProviderHelpers.readText("~/.grok/auth.json"),
              let data = text.data(using: .utf8),
              let auth = try? JSONDecoder().decode([String: GrokAuthEntry].self, from: data)
        else {
            return nil
        }
        for entry in auth.values {
            guard let token = entry.key?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { continue }
            return token
        }
        return nil
    }

    private func mapBilling(_ data: Data, plan: String?) -> ProviderSnapshot {
        guard let body = ProviderHelpers.jsonObject(data),
              let config = body["config"] as? [String: Any],
              let used = unitsValue(config["used"]),
              let limit = unitsValue(config["monthlyLimit"]),
              limit > 0
        else {
            return .error(info, "Grok billing response changed.")
        }
        var metrics = [
            UsageMetric(
                label: "Monthly",
                used: ProviderHelpers.clampPercent((used / limit) * 100),
                limit: 100,
                resetsAt: ProviderHelpers.isoDate(config["billingPeriodEnd"])
            ),
        ]
        if let cap = unitsValue(config["onDemandCap"]), cap > 0 {
            metrics.append(UsageMetric(label: "Pay as you go", used: 0, limit: cap, kind: .count("credits")))
        }
        return .ok(info, plan: plan, metrics: metrics, at: now())
    }

    private nonisolated func unitsValue(_ value: Any?) -> Double? {
        guard let object = value as? [String: Any],
              let number = ProviderHelpers.number(object["val"])
        else {
            return nil
        }
        return number.isFinite ? number : nil
    }

    private nonisolated func planName(_ response: HTTPResponse?) -> String? {
        guard let response,
              response.isSuccess,
              let body = ProviderHelpers.jsonObject(response.body),
              let plan = (body["subscription_tier_display"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty
        else {
            return nil
        }
        return plan
    }
}

struct GrokUsageClient: Sendable {
    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    var http = HTTPClient()

    func fetchBilling(accessToken: String) async throws -> HTTPResponse {
        try await get(Self.billingURL, accessToken: accessToken)
    }

    func fetchSettings(accessToken: String) async throws -> HTTPResponse {
        try await get(Self.settingsURL, accessToken: accessToken)
    }

    private func get(_ url: URL, accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                "X-XAI-Token-Auth": "xai-grok-cli",
                "Accept": "application/json",
                "User-Agent": "Usage",
            ],
            timeout: 10
        ))
    }
}
