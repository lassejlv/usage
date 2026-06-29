import Foundation

struct DevinAuth: Sendable, Equatable {
    var apiKey: String
    var apiServerURL: String
}

actor DevinProvider: UsageProvider {
    nonisolated let info = ProviderInfo(id: "devin", displayName: "Devin", fallbackSymbol: "bolt")

    private let client = DevinUsageClient()
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = loadAuth() else {
            return .error(info, "Run devin auth login or sign in to Devin.")
        }
        do {
            let response = try await client.fetchUserStatus(auth: auth)
            if response.statusCode == 401 || response.statusCode == 403 {
                return .error(info, "Devin auth expired. Sign in again.")
            }
            guard response.isSuccess,
                  let body = ProviderHelpers.jsonObject(response.body),
                  let userStatus = body["userStatus"] as? [String: Any]
            else {
                return .error(info, "Devin quota data unavailable.")
            }
            return map(userStatus)
        } catch {
            return .error(info, "Couldn't reach Devin. Check your connection.")
        }
    }

    private nonisolated func loadAuth() -> DevinAuth? {
        if let text = ProviderHelpers.readText("~/.local/share/devin/credentials.toml"),
           let key = ProviderHelpers.tomlString(text, key: "windsurf_api_key") {
            let rawURL = ProviderHelpers.tomlString(text, key: "api_server_url")
            let server = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return DevinAuth(apiKey: key, apiServerURL: server?.hasPrefix("https://") == true ? server! : DevinUsageClient.defaultAPIServerURL)
        }
        let sql = "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1;"
        guard let value = ProviderHelpers.sqliteValue(path: "~/Library/Application Support/Devin/User/globalStorage/state.vscdb", sql: sql),
              let auth = ProviderHelpers.jsonObject(value),
              let key = (auth["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else {
            return nil
        }
        return DevinAuth(apiKey: key, apiServerURL: DevinUsageClient.defaultAPIServerURL)
    }

    private func map(_ userStatus: [String: Any]) -> ProviderSnapshot {
        let planStatus = userStatus["planStatus"] as? [String: Any] ?? [:]
        let planInfo = planStatus["planInfo"] as? [String: Any] ?? [:]
        let plan = (planInfo["planName"] as? String) ?? "Unknown"
        let hideDaily = ProviderHelpers.bool(planInfo["hideDailyQuota"]) == true
        var metrics: [UsageMetric] = []

        if !hideDaily, let remaining = ProviderHelpers.number(planStatus["dailyQuotaRemainingPercent"]) {
            metrics.append(UsageMetric(
                label: "Daily quota",
                used: ProviderHelpers.clampPercent(100 - remaining),
                limit: 100,
                resetsAt: ProviderHelpers.isoDate(planStatus["dailyQuotaResetAtUnix"])
            ))
        }
        if let remaining = ProviderHelpers.number(planStatus["weeklyQuotaRemainingPercent"]) {
            metrics.append(UsageMetric(
                label: "Weekly quota",
                used: ProviderHelpers.clampPercent(100 - remaining),
                limit: 100,
                resetsAt: ProviderHelpers.isoDate(planStatus["weeklyQuotaResetAtUnix"])
            ))
        }
        if let micros = ProviderHelpers.number(planStatus["overageBalanceMicros"]) {
            metrics.append(UsageMetric(label: "Extra usage balance", used: 0, limit: max(0, micros) / 1_000_000, kind: .dollars))
        }
        guard !metrics.isEmpty else { return .error(info, "Devin quota data unavailable.") }
        return .ok(info, plan: plan, metrics: metrics, at: now())
    }
}

struct DevinUsageClient: Sendable {
    static let defaultAPIServerURL = "https://server.codeium.com"
    private static let cloudService = "exa.seat_management_pb.SeatManagementService"
    private static let cloudCompatVersion = "1.108.2"
    var http = HTTPClient()

    func fetchUserStatus(auth: DevinAuth) async throws -> HTTPResponse {
        let url = URL(string: "\(auth.apiServerURL)/\(Self.cloudService)/GetUserStatus")!
        let body: [String: Any] = [
            "metadata": [
                "apiKey": auth.apiKey,
                "ideName": "devin",
                "ideVersion": Self.cloudCompatVersion,
                "extensionName": "devin",
                "extensionVersion": Self.cloudCompatVersion,
                "locale": "en",
            ],
        ]
        return try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/json", "Connect-Protocol-Version": "1"],
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 15
        ))
    }
}
