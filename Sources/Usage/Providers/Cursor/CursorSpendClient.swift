import Foundation

/// Fetches Cursor token + dollar spend by exporting the dashboard usage CSV and pricing it locally.
/// Mirrors openusage: the `WorkosCursorSessionToken` cookie is derived from the Bearer access token
/// (`userID%3A%3A<accessToken>`, userID from the JWT subject), the CSV carries per-event token counts,
/// and dollars are imputed from the bundled model pricing manifest. Returns nil on any failure so the
/// Cost block simply doesn't appear.
struct CursorSpendClient: Sendable {
    static let exportCSVURL = URL(string: "https://cursor.com/api/dashboard/export-usage-events-csv")!

    var http: HTTPClient

    init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    func spend(accessToken: String, daysBack: Int = 30, now: Date = Date()) async -> SpendSummary? {
        guard let sessionToken = Self.sessionToken(accessToken: accessToken) else { return nil }

        let calendar = Calendar.current
        let end = now
        let start = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: now)) ?? now

        var components = URLComponents(url: Self.exportCSVURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "startDate", value: String(Int(start.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "endDate", value: String(Int(end.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "strategy", value: "tokens"),
        ]
        guard let url = components?.url else { return nil }

        guard let response = try? await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Cookie": "WorkosCursorSessionToken=\(sessionToken)",
                "Accept": "text/csv",
            ],
            timeout: 30
        )), response.isSuccess, let csv = String(data: response.body, encoding: .utf8) else {
            return nil
        }

        // Parsing + pricing a month of events is CPU work, so run it off the actor.
        return await Task.detached(priority: .utility) {
            Self.summarize(csv: csv, now: now)
        }.value
    }

    /// `userID%3A%3A<accessToken>` — the same cookie the Cursor web dashboard sends. userID is the JWT
    /// subject's trailing segment (e.g. `auth0|user_123` → `user_123`).
    static func sessionToken(accessToken: String) -> String? {
        guard let subject = CursorAuthStore.tokenSubject(accessToken) else { return nil }
        let parts = subject.split(separator: "|", omittingEmptySubsequences: false)
        let userID = String(parts.count > 1 ? parts[1] : parts[0])
        guard !userID.isEmpty else { return nil }
        return "\(userID)%3A%3A\(accessToken)"
    }

    private static func summarize(csv: String, now: Date) -> SpendSummary? {
        let rows = CursorUsageCSV.parse(csv: csv)
        guard !rows.isEmpty else { return nil }

        var tokensByDay: [String: Int] = [:]
        var costByDay: [String: Double] = [:]
        for row in rows {
            let key = dayKey(from: row.date)
            tokensByDay[key, default: 0] += row.tokens.total
            costByDay[key, default: 0] += row.costDollars
        }

        let todayKey = dayKey(from: now)
        var today: SpendSummary.Period?
        if let tokens = tokensByDay[todayKey], tokens > 0 || (costByDay[todayKey] ?? 0) > 0 {
            today = SpendSummary.Period(costUSD: costByDay[todayKey], tokens: tokens)
        }

        let totalTokens = tokensByDay.values.reduce(0, +)
        let totalCost = costByDay.values.reduce(0, +)
        var last30Days: SpendSummary.Period?
        if totalTokens > 0 || totalCost > 0 {
            last30Days = SpendSummary.Period(costUSD: totalCost, tokens: totalTokens)
        }

        guard today != nil || last30Days != nil else { return nil }

        let daily = tokensByDay.keys.compactMap { key -> SpendSummary.Day? in
            guard let date = ProviderHelpers.date(fromDayKey: key) else { return nil }
            return SpendSummary.Day(date: date, tokens: tokensByDay[key] ?? 0, costUSD: costByDay[key])
        }.sorted { $0.date < $1.date }

        return SpendSummary(today: today, last30Days: last30Days, estimated: true, daily: daily)
    }

    private static func dayKey(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
