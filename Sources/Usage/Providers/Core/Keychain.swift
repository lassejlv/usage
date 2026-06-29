import Foundation
import Security

/// Minimal read-only access to macOS generic-password keychain items. Claude Code stores its OAuth
/// credentials here, so reading them may trigger the system "wants to access your keychain" prompt the
/// first time — that's expected for an app reading another app's item.
enum Keychain {
    static func readGenericPassword(service: String) -> String? {
        readGenericPassword(service: service, account: nil)
    }

    static func readGenericPassword(service: String, account: String?) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ].merging(account.map { [kSecAttrAccount as String: $0] } ?? [:]) { current, _ in current }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }
}
