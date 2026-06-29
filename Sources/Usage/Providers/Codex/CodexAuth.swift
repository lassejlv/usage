import Foundation

struct CodexOAuth: Decodable, Hashable, Sendable {
    var accessToken: String?
    var idToken: String?
    var refreshToken: String?
    var accountID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }
}

private struct CodexAuthFile: Decodable, Sendable {
    var tokens: CodexOAuth?
}

enum CodexAuthError: Error, LocalizedError {
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Not logged in. Run `codex login` to authenticate."
        }
    }
}

/// Loads Codex OAuth credentials from the same locations used by the Codex CLI.
struct CodexAuthStore: Sendable {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func load() -> CodexOAuth? {
        if let token = envToken() {
            var oauth = loadFromFile() ?? loadFromKeychain() ?? CodexOAuth()
            oauth.accessToken = token
            return oauth
        }
        return loadFromFile() ?? loadFromKeychain()
    }

    private func envToken() -> String? {
        guard let value = ProcessInfo.processInfo.environment["CODEX_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func loadFromFile() -> CodexOAuth? {
        for path in candidateAuthPaths() {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let oauth = parse(text)
            else {
                continue
            }
            return oauth
        }
        return nil
    }

    private func loadFromKeychain() -> CodexOAuth? {
        guard let text = Keychain.readGenericPassword(service: "Codex Auth") else { return nil }
        return parse(text)
    }

    private func parse(_ text: String) -> CodexOAuth? {
        guard let data = text.data(using: .utf8),
              let file = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
              let oauth = file.tokens,
              oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        return oauth
    }

    private func candidateAuthPaths() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        var dirs: [String] = []

        if let codexHome = env["CODEX_HOME"], !codexHome.isEmpty {
            dirs.append(codexHome)
        }
        if let configHome = env["XDG_CONFIG_HOME"], !configHome.isEmpty {
            dirs.append(configHome + "/codex")
        } else {
            dirs.append(home + "/.config/codex")
        }
        dirs.append(home + "/.codex")

        var seen = Set<String>()
        return dirs
            .map { $0 + "/auth.json" }
            .filter { seen.insert($0).inserted }
    }
}
