import Foundation

private struct AntigravityKeychainToken: Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiry: Date?
}

actor AntigravityProvider: UsageProvider {
    nonisolated let info = ProviderInfo(id: "antigravity", displayName: "Antigravity", fallbackSymbol: "atom")

    private let client = AntigravityUsageClient()
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func refresh() async -> ProviderSnapshot {
        guard let token = loadToken(),
              let access = token.accessToken,
              token.expiry.map({ $0.timeIntervalSince(now()) > 60 }) ?? true
        else {
            return .error(info, "Start Antigravity or run `agy` and try again.")
        }

        switch await client.fetchAvailableModels(token: access) {
        case .success(let data):
            let metrics = buildMetrics(parseCloudCodeModels(data))
            if !metrics.isEmpty {
                return .ok(info, plan: await loadPlan(token: access), metrics: metrics, at: now())
            }
        case .authFailed:
            return .error(info, "Antigravity sign-in expired. Open Antigravity or run `agy`.")
        case .unavailable:
            break
        }

        switch await client.loadCodeAssist(token: access) {
        case .success(let data):
            let plan = parseLoadCodeAssistPlan(data)
            let project = parseProject(data)
            switch await client.retrieveQuota(token: access, project: project) {
            case .success(let quota):
                let metrics = buildMetrics(parseQuotaBuckets(quota))
                if !metrics.isEmpty {
                    return .ok(info, plan: plan, metrics: metrics, at: now())
                }
            case .authFailed:
                return .error(info, "Antigravity sign-in expired. Open Antigravity or run `agy`.")
            case .unavailable:
                break
            }
        case .authFailed:
            return .error(info, "Antigravity sign-in expired. Open Antigravity or run `agy`.")
        case .unavailable:
            break
        }

        return .error(info, "Antigravity usage is temporarily unavailable.")
    }

    private nonisolated func loadToken() -> AntigravityKeychainToken? {
        guard let raw = Keychain.readGenericPassword(service: "gemini", account: "antigravity") else { return nil }
        return extractToken(raw)
    }

    private nonisolated func extractToken(_ raw: String) -> AntigravityKeychainToken? {
        guard let text = unwrapGoKeyring(raw) else { return nil }
        if let object = ProviderHelpers.jsonObject(text) {
            return tokenFromObject(object)
        }
        if text.hasPrefix("Bearer ") {
            let token = String(text.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : AntigravityKeychainToken(accessToken: token, refreshToken: nil, expiry: nil)
        }
        return AntigravityKeychainToken(accessToken: text, refreshToken: nil, expiry: nil)
    }

    private nonisolated func unwrapGoKeyring(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            let encoded = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    private nonisolated func tokenFromObject(_ object: [String: Any]) -> AntigravityKeychainToken? {
        let source = (object["token"] as? [String: Any]) ?? object
        let access = firstString(source, ["access_token", "accessToken", "token", "id_token", "idToken", "bearerToken", "auth_token", "authToken"])
        let refresh = firstString(source, ["refresh_token", "refreshToken"])
        let expiry = firstString(source, ["expiry", "expires_at", "expiresAt"]).flatMap(ProviderHelpers.isoDate)
        if access == nil, refresh == nil {
            for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
                if let nested = object[key] as? [String: Any], let token = tokenFromObject(nested) {
                    return token
                }
            }
            return nil
        }
        return AntigravityKeychainToken(accessToken: access, refreshToken: refresh, expiry: expiry)
    }

    private nonisolated func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func loadPlan(token: String) async -> String? {
        if case .success(let data) = await client.loadCodeAssist(token: token) {
            return parseLoadCodeAssistPlan(data)
        }
        return nil
    }

    private nonisolated func buildMetrics(_ configs: [AntigravityModelConfig]) -> [UsageMetric] {
        var pooled: [String: (fraction: Double, reset: Date?)] = [:]
        for config in configs {
            let label = config.label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !blacklist.contains(config.modelID ?? "") else { continue }
            let pool = poolLabel(label)
            if let existing = pooled[pool] {
                if config.remainingFraction < existing.fraction {
                    pooled[pool] = (config.remainingFraction, config.resetTime)
                }
            } else {
                pooled[pool] = (config.remainingFraction, config.resetTime)
            }
        }
        return pooled.sorted { sortKey($0.key) < sortKey($1.key) }.map { pool, value in
            UsageMetric(
                label: pool,
                used: ProviderHelpers.clampPercent((1 - max(0, min(1, value.fraction))) * 100),
                limit: 100,
                resetsAt: value.reset
            )
        }
    }

    private nonisolated var blacklist: Set<String> {
        [
            "MODEL_CHAT_20706", "MODEL_CHAT_23310",
            "MODEL_GOOGLE_GEMINI_2_5_FLASH", "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING",
            "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE", "MODEL_GOOGLE_GEMINI_2_5_PRO",
            "MODEL_PLACEHOLDER_M19", "MODEL_PLACEHOLDER_M9", "MODEL_PLACEHOLDER_M12",
        ]
    }

    private nonisolated func poolLabel(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        let lower = normalized.lowercased()
        if lower.contains("gemini") {
            return lower.contains("flash") ? "Gemini Flash" : "Gemini Pro"
        }
        return "Claude"
    }

    private nonisolated func sortKey(_ pool: String) -> String {
        let lower = pool.lowercased()
        if lower.contains("gemini"), lower.contains("pro") { return "0_\(pool)" }
        if lower.contains("gemini") { return "1_\(pool)" }
        return "2_\(pool)"
    }

    private nonisolated func parseCloudCodeModels(_ data: Data) -> [AntigravityModelConfig] {
        guard let envelope = try? JSONDecoder().decode(CCModelsEnvelope.self, from: data),
              let models = envelope.models
        else {
            return []
        }
        return models.compactMap { key, model in
            if model.isInternal == true { return nil }
            guard let label = model.displayName ?? model.label else { return nil }
            return AntigravityModelConfig(
                label: label,
                modelID: model.model ?? key,
                remainingFraction: model.quotaInfo?.remainingFraction ?? 0,
                resetTime: model.quotaInfo?.resetTime.flatMap(ProviderHelpers.isoDate)
            )
        }
    }

    private nonisolated func parseQuotaBuckets(_ data: Data) -> [AntigravityModelConfig] {
        guard let envelope = try? JSONDecoder().decode(CCQuotaEnvelope.self, from: data),
              let buckets = envelope.buckets
        else {
            return []
        }
        return buckets.compactMap { bucket in
            guard let id = bucket.modelId else { return nil }
            return AntigravityModelConfig(
                label: id,
                modelID: id,
                remainingFraction: bucket.remainingFraction ?? 0,
                resetTime: bucket.resetTime.flatMap(ProviderHelpers.isoDate)
            )
        }
    }

    private nonisolated func parseLoadCodeAssistPlan(_ data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(CCLoadEnvelope.self, from: data) else { return nil }
        return formatPlan(envelope.paidTier?.name ?? envelope.currentTier?.name)
    }

    private nonisolated func parseProject(_ data: Data) -> String? {
        (try? JSONDecoder().decode(CCLoadEnvelope.self, from: data))?.cloudaicompanionProject
    }

    private nonisolated func formatPlan(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.hasPrefix("Google AI ") {
            return ProviderHelpers.title(String(raw.dropFirst("Google AI ".count)))
        }
        for keyword in ["Ultra", "Pro", "Free"] where raw.lowercased().contains(keyword.lowercased()) {
            return keyword
        }
        return ProviderHelpers.title(raw)
    }
}

private struct AntigravityModelConfig: Sendable {
    var label: String
    var modelID: String?
    var remainingFraction: Double
    var resetTime: Date?
}

private struct AntigravityQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
}

private struct CCModelsEnvelope: Decodable {
    let models: [String: CCModel]?
    struct CCModel: Decodable {
        let model: String?
        let displayName: String?
        let label: String?
        let isInternal: Bool?
        let quotaInfo: AntigravityQuotaInfo?
    }
}

private struct CCLoadEnvelope: Decodable {
    let cloudaicompanionProject: String?
    let currentTier: Tier?
    let paidTier: Tier?
    struct Tier: Decodable { let name: String? }
}

private struct CCQuotaEnvelope: Decodable {
    let buckets: [Bucket]?
    struct Bucket: Decodable {
        let modelId: String?
        let remainingFraction: Double?
        let resetTime: String?
    }
}

private enum AntigravityCloudOutcome: Sendable {
    case success(Data)
    case authFailed
    case unavailable
}

struct AntigravityUsageClient: Sendable {
    static let cloudCodeURLs = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com",
    ]
    static let fetchModelsPath = "/v1internal:fetchAvailableModels"
    static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    static let retrieveQuotaPath = "/v1internal:retrieveUserQuota"
    var http = HTTPClient()

    fileprivate func fetchAvailableModels(token: String) async -> AntigravityCloudOutcome {
        await cloudCode(path: Self.fetchModelsPath, token: token, userAgent: "antigravity", body: [:])
    }

    fileprivate func loadCodeAssist(token: String) async -> AntigravityCloudOutcome {
        await cloudCode(path: Self.loadCodeAssistPath, token: token, userAgent: "agy", body: [:])
    }

    fileprivate func retrieveQuota(token: String, project: String?) async -> AntigravityCloudOutcome {
        await cloudCode(path: Self.retrieveQuotaPath, token: token, userAgent: "agy", body: project.map { ["project": $0] } ?? [:])
    }

    fileprivate func cloudCode(path: String, token: String, userAgent: String, body: [String: String]) async -> AntigravityCloudOutcome {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        for base in Self.cloudCodeURLs {
            guard let url = URL(string: base + path) else { continue }
            let request = HTTPRequest(
                method: "POST",
                url: url,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": "Bearer \(token)",
                    "User-Agent": userAgent,
                ],
                body: payload,
                timeout: 15
            )
            guard let response = try? await http.send(request) else { continue }
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailed }
            if response.isSuccess { return .success(response.body) }
        }
        return .unavailable
    }
}
