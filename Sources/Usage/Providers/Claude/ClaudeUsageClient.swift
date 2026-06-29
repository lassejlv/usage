import Foundation

private struct ClaudeRefreshResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// Talks to the two Claude OAuth endpoints: token refresh and the usage read.
struct ClaudeUsageClient: Sendable {
    private static let scopes =
        "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    private static let userAgent = "claude-code/2.1.69"

    var http: HTTPClient

    init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: ClaudeAuthStore.usageURL,
            headers: [
                "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                "Accept": "application/json",
                "Content-Type": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": Self.userAgent,
            ],
            timeout: 10
        ))
    }

    /// Exchange a refresh token for a fresh access token. Returns the updated OAuth fields applied onto
    /// `oauth`, or nil if the response wasn't a usable token grant.
    func refresh(_ oauth: ClaudeOAuth, now: Date) async throws -> ClaudeOAuth? {
        guard let refreshToken = oauth.refreshToken, !refreshToken.isEmpty else { return nil }

        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": ClaudeAuthStore.clientID,
            "scope": Self.scopes,
        ]
        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: ClaudeAuthStore.refreshURL,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 15
        ))

        if response.statusCode == 400 || response.statusCode == 401 {
            throw ClaudeAuthError.sessionExpired
        }
        guard response.isSuccess,
              let decoded = try? JSONDecoder().decode(ClaudeRefreshResponse.self, from: response.body)
        else {
            return nil
        }

        var updated = oauth
        updated.accessToken = decoded.accessToken
        if let refreshToken = decoded.refreshToken { updated.refreshToken = refreshToken }
        if let expiresIn = decoded.expiresIn {
            updated.expiresAt = now.timeIntervalSince1970 * 1000 + expiresIn * 1000
        }
        return updated
    }
}
