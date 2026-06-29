import Foundation

struct CursorUsageClient: Sendable {
    static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    static let planURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!
    static let creditsURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance")!
    static let refreshURL = URL(string: "https://api2.cursor.sh/oauth/token")!
    static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    var http: HTTPClient

    init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.usageURL, accessToken: accessToken)
    }

    func fetchPlan(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.planURL, accessToken: accessToken)
    }

    func fetchCredits(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.creditsURL, accessToken: accessToken)
    }

    func refreshToken(_ refreshToken: String) async throws -> HTTPResponse {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
        ]
        return try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 15
        ))
    }

    private func connectPost(_ url: URL, accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
            ],
            body: Data("{}".utf8),
            timeout: 10
        ))
    }
}
