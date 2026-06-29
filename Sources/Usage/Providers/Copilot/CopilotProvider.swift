import Foundation

actor CopilotProvider: UsageProvider {
    nonisolated let info = ProviderInfo(id: "copilot", displayName: "Copilot", fallbackSymbol: "chevron.left.forwardslash.chevron.right")

    private let client = CopilotUsageClient()
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func refresh() async -> ProviderSnapshot {
        guard let token = loadToken() else {
            return .error(info, "Sign in to GitHub Copilot or run gh auth login.")
        }
        do {
            let response = try await client.fetchUsage(token: token)
            if response.statusCode == 401 || response.statusCode == 403 {
                return .error(info, "GitHub token invalid or expired.")
            }
            guard response.isSuccess, let body = ProviderHelpers.jsonObject(response.body) else {
                return .error(info, "Copilot usage request failed (\(response.statusCode)).")
            }
            return map(body)
        } catch {
            return .error(info, "Couldn't reach GitHub. Check your connection.")
        }
    }

    private nonisolated func loadToken() -> String? {
        for path in ["~/.config/github-copilot/apps.json", "~/.config/github-copilot/hosts.json"] {
            guard let text = ProviderHelpers.readText(path),
                  let object = ProviderHelpers.jsonObject(text)
            else {
                continue
            }
            for (key, value) in object where key == "github.com" || key.hasPrefix("github.com:") {
                if let dict = value as? [String: Any],
                   let token = (dict["oauth_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !token.isEmpty {
                    return token
                }
            }
        }
        if let text = ProviderHelpers.readText("~/.config/gh/hosts.yml"),
           let token = yamlValue(text, key: "oauth_token") {
            return token
        }
        if let raw = Keychain.readGenericPassword(service: "gh:github.com") {
            return unwrapGoKeyring(raw)
        }
        return nil
    }

    private nonisolated func yamlValue(_ text: String, key: String) -> String? {
        let prefix = key + ":"
        var inGitHub = false
        for line in text.split(whereSeparator: \.isNewline) {
            if let first = line.first, !first.isWhitespace {
                inGitHub = line.trimmingCharacters(in: .whitespaces).hasPrefix("github.com:")
                continue
            }
            guard inGitHub else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
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

    private func map(_ body: [String: Any]) -> ProviderSnapshot {
        let plan = ProviderHelpers.title(body["copilot_plan"] as? String)
        let resetsAt = ProviderHelpers.isoDate(body["quota_reset_date"]) ?? ProviderHelpers.isoDate(body["limited_user_reset_date"])
        var metrics: [UsageMetric] = []

        let snapshots = body["quota_snapshots"] as? [String: Any]
        appendSnapshot(snapshots?["premium_interactions"], label: "Premium", resetsAt: resetsAt, into: &metrics)
        appendSnapshot(snapshots?["chat"], label: "Chat", resetsAt: resetsAt, into: &metrics)
        appendSnapshot(snapshots?["completions"], label: "Completions", resetsAt: resetsAt, into: &metrics)

        if metrics.isEmpty {
            let limited = body["limited_user_quotas"] as? [String: Any]
            let monthly = body["monthly_quotas"] as? [String: Any]
            appendLimited(remaining: limited?["chat"], total: monthly?["chat"], label: "Chat", resetsAt: resetsAt, into: &metrics)
            appendLimited(remaining: limited?["completions"], total: monthly?["completions"], label: "Completions", resetsAt: resetsAt, into: &metrics)
        }
        return .ok(info, plan: plan, metrics: metrics, at: now())
    }

    private nonisolated func appendSnapshot(_ raw: Any?, label: String, resetsAt: Date?, into metrics: inout [UsageMetric]) {
        guard let snapshot = raw as? [String: Any] else { return }
        if ProviderHelpers.bool(snapshot["unlimited"]) == true {
            metrics.append(UsageMetric(label: label, used: 0, limit: 100))
            return
        }
        if ProviderHelpers.number(snapshot["entitlement"]) == 0 { return }
        let used: Double?
        if let remaining = ProviderHelpers.number(snapshot["percent_remaining"]) {
            used = 100 - remaining
        } else if let entitlement = ProviderHelpers.number(snapshot["entitlement"]),
                  entitlement > 0,
                  let remaining = ProviderHelpers.number(snapshot["remaining"]) {
            used = 100 - (remaining / entitlement) * 100
        } else {
            used = nil
        }
        guard let used else { return }
        metrics.append(UsageMetric(label: label, used: ProviderHelpers.clampPercent(used), limit: 100, resetsAt: resetsAt))
    }

    private nonisolated func appendLimited(remaining: Any?, total: Any?, label: String, resetsAt: Date?, into metrics: inout [UsageMetric]) {
        guard let total = ProviderHelpers.number(total), total > 0,
              let remaining = ProviderHelpers.number(remaining)
        else {
            return
        }
        metrics.append(UsageMetric(label: label, used: ProviderHelpers.clampPercent(((total - remaining) / total) * 100), limit: 100, resetsAt: resetsAt))
    }
}

struct CopilotUsageClient: Sendable {
    static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!
    var http = HTTPClient()

    func fetchUsage(token: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageURL,
            headers: [
                "Authorization": "token \(token)",
                "Accept": "application/json",
                "Editor-Version": "vscode/1.96.2",
                "Editor-Plugin-Version": "copilot-chat/0.26.7",
                "User-Agent": "GitHubCopilotChat/0.26.7",
                "X-Github-Api-Version": "2025-04-01",
            ],
            timeout: 15
        ))
    }
}
