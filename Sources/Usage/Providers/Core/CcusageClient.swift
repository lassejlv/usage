import Foundation

/// Fetches token + dollar spend for Claude/Codex by shelling out to the `ccusage` npm CLI, which
/// reads the local Claude Code / Codex JSONL logs and prices them at API rates. Mirrors openusage's
/// approach: resolve a package runner (bunx → pnpm dlx → yarn dlx → npm exec → npx) with a
/// GUI-enriched PATH, run `ccusage <tool> daily --json --since <yyyyMMdd>`, then sum the daily series
/// into Today + Last 30 Days totals.
///
/// Returns nil when no package runner is available or ccusage fails, so a missing Node/Bun toolchain
/// simply hides the Cost block rather than surfacing an error.
final class CcusageClient: @unchecked Sendable {
    enum Tool: String, Sendable {
        case claude
        case codex
    }

    enum Runner: CaseIterable {
        case bunx, pnpmDlx, yarnDlx, npmExec, npx
    }

    private static let packageSpec = "ccusage@20.0.14"
    private static let binName = "ccusage"
    private static let timeout: TimeInterval = 20
    private static let probeTimeout: TimeInterval = 2

    /// The runner that last ran ccusage successfully, memoized so the periodic refresh skips
    /// re-resolution (and its `--version` probe spawns). Cleared on failure so a broken runner is
    /// re-resolved next time.
    private let lock = NSLock()
    private var resolvedRunner: (kind: Runner, program: String)?

    func spend(for tool: Tool, daysBack: Int = 30, now: Date = Date()) async -> SpendSummary? {
        // The blocking subprocess work runs on a background thread so it never stalls the caller's
        // actor (the Claude/Codex provider).
        await Task.detached(priority: .utility) { [self] in
            computeSpend(tool: tool, daysBack: daysBack, now: now)
        }.value
    }

    // MARK: - Core (runs off-actor)

    private func computeSpend(tool: Tool, daysBack: Int, now: Date) -> SpendSummary? {
        let since = Self.sinceString(daysBack: daysBack, from: now)
        guard let days = runCcusage(tool: tool, since: since) else { return nil }
        return Self.summarize(days, now: now)
    }

    private func runCcusage(tool: Tool, since: String) -> [DailyUsage]? {
        let environment = Self.pathEnvironment()

        // Fast path: re-use the runner that worked last time.
        if let cached = withLock({ resolvedRunner }) {
            if let days = attempt(kind: cached.kind, program: cached.program, tool: tool, since: since, environment: environment) {
                return days
            }
            withLock { resolvedRunner = nil }
        }

        // Resolve runners in priority order, stopping at the first that runs ccusage.
        for kind in Runner.allCases {
            guard let program = resolveRunner(kind) else { continue }
            if let days = attempt(kind: kind, program: program, tool: tool, since: since, environment: environment) {
                withLock { resolvedRunner = (kind, program) }
                return days
            }
        }
        return nil
    }

    private func attempt(kind: Runner, program: String, tool: Tool, since: String, environment: [String: String]) -> [DailyUsage]? {
        let arguments = Self.runnerArgs(kind: kind, tool: tool, since: since, timezone: TimeZone.current.identifier)
        guard let result = try? ProcessRunner.run(
            executable: program, arguments: arguments, environment: environment, timeout: Self.timeout
        ), result.succeeded else {
            return nil
        }
        return Self.parse(result.stdout)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - Runner resolution

    /// First working program for `kind`: absolute candidates are checked on disk; a bare command name
    /// is probed with `--version` so PATH resolution (incl. version managers) applies.
    private func resolveRunner(_ kind: Runner) -> String? {
        for candidate in Self.runnerCandidates(kind, home: Self.home) {
            if candidate.hasPrefix("/") {
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            } else if commandExists(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func commandExists(_ command: String) -> Bool {
        guard let result = try? ProcessRunner.run(
            executable: command, arguments: ["--version"], environment: Self.pathEnvironment(), timeout: Self.probeTimeout
        ) else {
            return false
        }
        return result.succeeded
    }

    static func runnerCandidates(_ kind: Runner, home: URL) -> [String] {
        switch kind {
        case .bunx:
            return [
                home.appendingPathComponent(".bun/bin/bunx").path,
                "/opt/homebrew/bin/bunx", "/usr/local/bin/bunx", "bunx",
            ]
        case .pnpmDlx:
            return ["/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm", "pnpm"]
        case .yarnDlx:
            return ["/opt/homebrew/bin/yarn", "/usr/local/bin/yarn", "yarn"]
        case .npmExec:
            return ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", "npm"]
        case .npx:
            return ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "npx"]
        }
    }

    /// Argument vector for `kind`, ending in the shared `ccusage <tool> daily …` invocation. The IANA
    /// `--timezone` makes ccusage bucket days in the local zone the app uses for "today", so the most
    /// recent usage doesn't land in a UTC bucket the local lookup misses.
    static func runnerArgs(kind: Runner, tool: Tool, since: String, timezone: String) -> [String] {
        let leading: [String]
        switch kind {
        case .bunx: leading = ["--silent", packageSpec]
        case .pnpmDlx: leading = ["-s", "dlx", packageSpec]
        case .yarnDlx: leading = ["dlx", "-q", packageSpec]
        case .npmExec: leading = ["exec", "--yes", "--package=\(packageSpec)", "--", binName]
        case .npx: leading = ["--yes", packageSpec]
        }
        return leading + [tool.rawValue, "daily", "--json", "--order", "desc", "--since", since, "--timezone", timezone]
    }

    // MARK: - Environment / PATH

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static func pathEnvironment() -> [String: String] {
        ["PATH": pathEntries(home: home, existingPath: ProcessInfo.processInfo.environment["PATH"]).joined(separator: ":")]
    }

    /// PATH entries to prepend before probing/launching runners: Bun, nvm (current + default alias),
    /// `~/.local/bin`, Homebrew, then the inherited PATH. A GUI menu-bar app inherits a stripped PATH,
    /// so version-manager bins must be added explicitly.
    static func pathEntries(home: URL, existingPath: String?) -> [String] {
        var entries: [String] = [
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".nvm/current/bin").path,
        ]
        if let nvmDefault = nvmDefaultBinPath(home: home) {
            entries.append(nvmDefault)
        }
        entries.append(home.appendingPathComponent(".local/bin").path)
        entries.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        if let existingPath, !existingPath.isEmpty {
            entries.append(contentsOf: existingPath.split(separator: ":").map(String.init))
        }
        var seen = Set<String>()
        return entries.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Resolves nvm's default alias to its node `bin` directory, following one level of alias
    /// indirection. nil if absent or unresolvable.
    static func nvmDefaultBinPath(home: URL) -> String? {
        let aliasDir = home.appendingPathComponent(".nvm/alias")
        guard let version = resolveNvmAlias("default", aliasDir: aliasDir) else { return nil }
        let normalized = version.hasPrefix("v") ? version : "v\(version)"
        return home.appendingPathComponent(".nvm/versions/node/\(normalized)/bin").path
    }

    private static func resolveNvmAlias(_ name: String, aliasDir: URL) -> String? {
        func read(_ alias: String) -> String? {
            guard let raw = try? String(contentsOfFile: aliasDir.appendingPathComponent(alias).path, encoding: .utf8)
            else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        func isVersion(_ value: String) -> Bool { value.hasPrefix("v") || (value.first?.isNumber ?? false) }

        guard let value = read(name) else { return nil }
        if isVersion(value) { return value }
        guard let nested = read(value), isVersion(nested) else { return nil }
        return nested
    }

    // MARK: - Parsing

    /// One day's totals from ccusage's `daily` array.
    private struct DailyUsage {
        var date: String
        var tokens: Int
        var costUSD: Double?
    }

    static func sinceString(daysBack: Int, from date: Date) -> String {
        let since = Calendar.current.date(byAdding: .day, value: -daysBack, to: date) ?? date
        let components = Calendar.current.dateComponents([.year, .month, .day], from: since)
        return String(format: "%04d%02d%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func parse(_ stdout: String) -> [DailyUsage]? {
        guard let jsonText = extractLastJSONValue(stdout),
              let data = jsonText.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }

        let dailyRaw: [Any]
        if let array = raw as? [Any] {
            dailyRaw = array
        } else if let object = raw as? [String: Any], let daily = object["daily"] as? [Any] {
            dailyRaw = daily
        } else {
            return nil
        }

        return dailyRaw.compactMap { entry in
            guard let object = entry as? [String: Any], let date = object["date"] as? String else { return nil }
            let tokens = Int(ProviderHelpers.number(object["totalTokens"]) ?? 0)
            let cost = ProviderHelpers.number(object["totalCost"]) ?? ProviderHelpers.number(object["costUSD"])
            return DailyUsage(date: date, tokens: tokens, costUSD: cost)
        }
    }

    /// ccusage prints the JSON last; some runners prepend install chatter. Try the whole string, then
    /// the last `{`/`[`-rooted suffix that parses.
    private static func extractLastJSONValue(_ stdout: String) -> String? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil { return trimmed }

        let scalars = Array(trimmed)
        for index in scalars.indices.reversed() where scalars[index] == "{" || scalars[index] == "[" {
            let candidate = String(scalars[index...])
            if (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) != nil { return candidate }
        }
        return nil
    }

    // MARK: - Summing

    /// Today = the entry matching the local calendar day; Last 30 Days = the sum across the whole
    /// queried window. A period with zero tokens and zero cost is dropped (nil) so the UI reads
    /// "No data" rather than a fabricated `$0.00`.
    private static func summarize(_ days: [DailyUsage], now: Date) -> SpendSummary? {
        let todayKey = dayKey(from: now)
        var today: SpendSummary.Period?
        if let entry = days.first(where: { normalizedDayKey($0.date) == todayKey }), hasUsage(entry) {
            today = SpendSummary.Period(costUSD: entry.costUSD, tokens: entry.tokens)
        }

        let totalTokens = days.reduce(0) { $0 + $1.tokens }
        let costSamples = days.compactMap(\.costUSD)
        // Only surface a 30-day dollar total when every day is priced; otherwise the dollar would
        // cover a strict subset of the tokens shown beside it.
        let totalCost = (!days.isEmpty && costSamples.count == days.count) ? costSamples.reduce(0, +) : nil
        var last30Days: SpendSummary.Period?
        if totalTokens > 0 || (totalCost ?? 0) > 0 {
            last30Days = SpendSummary.Period(costUSD: totalCost, tokens: totalTokens)
        }

        guard today != nil || last30Days != nil else { return nil }
        return SpendSummary(today: today, last30Days: last30Days, estimated: true)
    }

    private static func hasUsage(_ entry: DailyUsage) -> Bool {
        entry.tokens > 0 || (entry.costUSD ?? 0) > 0
    }

    private static func dayKey(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Normalize ccusage's day string (`yyyy-MM-dd`, `yyyyMMdd`, `MMM dd, yyyy`, or ISO8601) to a
    /// `yyyy-MM-dd` key for comparison against the local "today".
    private static func normalizedDayKey(_ rawDate: String) -> String? {
        let value = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let match = value.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(value[match])
        }
        if value.range(of: #"^\d{8}$"#, options: .regularExpression) != nil {
            return "\(value.prefix(4))-\(value.dropFirst(4).prefix(2))-\(value.suffix(2))"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd, yyyy"
        if let date = formatter.date(from: value) { return dayKey(from: date) }
        if let date = ProviderHelpers.isoDate(value) { return dayKey(from: date) }
        return nil
    }
}
