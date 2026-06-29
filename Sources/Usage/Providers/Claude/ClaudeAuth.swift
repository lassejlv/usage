import Foundation

/// The OAuth blob Claude Code persists. Field names match the on-disk JSON (`claudeAiOauth`), so the
/// default Codable keys decode it directly.
struct ClaudeOAuth: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Double?          // epoch milliseconds
    var subscriptionType: String?
    var rateLimitTier: String?
    var scopes: [String]?
}

private struct ClaudeCredentialsFile: Codable, Sendable {
    var claudeAiOauth: ClaudeOAuth?
}

enum ClaudeAuthError: Error, LocalizedError {
    case notLoggedIn
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Not logged in. Run `claude` to authenticate."
        case .sessionExpired: "Session expired. Run `claude` to log in again."
        }
    }
}

/// Locates Claude Code's OAuth credentials. We look in three places, in priority order:
///   1. `CLAUDE_CODE_OAUTH_TOKEN` env var (an explicit access token, no refresh available)
///   2. the macOS keychain (`Claude Code-credentials`) — the source of truth on recent versions
///   3. `~/.claude/.credentials.json` — older installs / non-keychain layouts
struct ClaudeAuthStore: Sendable {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private static let keychainService = "Claude Code-credentials"

    /// The best available credential, or nil if the user isn't logged in anywhere.
    func load() -> ClaudeOAuth? {
        if let token = envToken() {
            var oauth = loadFromKeychain() ?? loadFromFile() ?? ClaudeOAuth()
            oauth.accessToken = token
            return oauth
        }
        return loadFromKeychain() ?? loadFromFile()
    }

    /// The usage endpoint requires the `user:profile` scope. A credential minted for inference only
    /// (e.g. `claude setup-token`, or an inference-scoped login) 403s on `/api/oauth/usage`, so we
    /// detect that and skip the call rather than surfacing a confusing error. Unknown scopes (nil/empty
    /// — e.g. a bare env token) are given the benefit of the doubt and still attempted.
    func canFetchLiveUsage(_ oauth: ClaudeOAuth) -> Bool {
        guard let scopes = oauth.scopes, !scopes.isEmpty else { return true }
        return scopes.contains("user:profile")
    }

    /// True when the access token is missing or within 5 minutes of expiry — refresh before using it.
    func needsRefresh(_ oauth: ClaudeOAuth, now: Date) -> Bool {
        guard let expiresAt = oauth.expiresAt else { return false }
        return expiresAt - now.timeIntervalSince1970 * 1000 <= 5 * 60 * 1000
    }

    /// Persist a rotated token back to the file (the only writable source here). Best-effort.
    func saveToFile(_ oauth: ClaudeOAuth) {
        let file = ClaudeCredentialsFile(claudeAiOauth: oauth)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: URL(fileURLWithPath: credentialsPath()))
    }

    // MARK: - Sources

    private func envToken() -> String? {
        guard let value = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func loadFromKeychain() -> ClaudeOAuth? {
        guard let text = Keychain.readGenericPassword(service: Self.keychainService) else { return nil }
        return parse(text)
    }

    private func loadFromFile() -> ClaudeOAuth? {
        guard let text = try? String(contentsOfFile: credentialsPath(), encoding: .utf8) else { return nil }
        return parse(text)
    }

    private func parse(_ text: String) -> ClaudeOAuth? {
        guard let data = text.data(using: .utf8),
              let file = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data),
              let oauth = file.claudeAiOauth,
              oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        return oauth
    }

    private func credentialsPath() -> String {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (NSHomeDirectory() + "/.claude")
        return home + "/.credentials.json"
    }
}
