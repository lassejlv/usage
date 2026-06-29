import Foundation

struct CodexUsageClient: Sendable {
    private static let userAgent = "codex-cli/0.1.0"

    var http: HTTPClient

    init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    func fetchUsage(oauth: CodexOAuth) async throws -> HTTPResponse {
        guard let accessToken = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else {
            throw CodexAuthError.notLoggedIn
        }

        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": Self.userAgent,
        ]
        if let accountID = oauth.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: CodexAuthStore.usageURL,
            headers: headers,
            timeout: 10
        ))
    }
}
