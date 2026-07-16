import Foundation
import Security

/// Secure storage for all app credentials.
///
/// All credentials are stored together in a **single Keychain item** as a
/// JSON blob. This minimizes Keychain access prompts — one unlock covers every
/// credential — instead of triggering a prompt per item on every save/load (the
/// previous per-field design caused up to 6 password prompts on each restart).
///
/// Older app versions stored each credential in its own Keychain item. On the first
/// `loadAll()` call, if the consolidated blob is missing, the legacy items are read
/// and migrated into the blob automatically (then deleted), so existing users keep
/// their configuration without any action.
enum KeychainHelper {
    private static let service = "com.louismasson.ClaudeUsageBar"
    private static let account = "credentials"

    // Legacy per-field accounts, kept only for one-time migration from older versions
    // that stored each credential in its own Keychain item.
    private static let legacyAccounts = [
        "claude_session_cookie",
        "claude_organization_id",
        "openrouter_api_key",
        "cline_session_cookie"
    ]

    struct Credentials: Codable {
        var organizationId: String = ""
        var sessionCookie: String = ""
        var openRouterAPIKey: String = ""
        var openRouterManagementKey: String = ""
        var clineSessionCookie: String = ""
        var githubToken: String = ""
        var vpsBaseURL: String = "https://status.patronusguardian.org"
        var vpsAPIToken: String = ""

        init(
            organizationId: String = "",
            sessionCookie: String = "",
            openRouterAPIKey: String = "",
            openRouterManagementKey: String = "",
            clineSessionCookie: String = "",
            githubToken: String = "",
            vpsBaseURL: String = "https://status.patronusguardian.org",
            vpsAPIToken: String = ""
        ) {
            self.organizationId = organizationId
            self.sessionCookie = sessionCookie
            self.openRouterAPIKey = openRouterAPIKey
            self.openRouterManagementKey = openRouterManagementKey
            self.clineSessionCookie = clineSessionCookie
            self.githubToken = githubToken
            self.vpsBaseURL = vpsBaseURL
            self.vpsAPIToken = vpsAPIToken
        }

        private enum CodingKeys: String, CodingKey {
            case organizationId, sessionCookie, openRouterAPIKey, openRouterManagementKey, clineSessionCookie
            case githubToken, vpsBaseURL, vpsAPIToken
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            organizationId = try c.decodeIfPresent(String.self, forKey: .organizationId) ?? ""
            sessionCookie = try c.decodeIfPresent(String.self, forKey: .sessionCookie) ?? ""
            openRouterAPIKey = try c.decodeIfPresent(String.self, forKey: .openRouterAPIKey) ?? ""
            openRouterManagementKey = try c.decodeIfPresent(String.self, forKey: .openRouterManagementKey) ?? ""
            clineSessionCookie = try c.decodeIfPresent(String.self, forKey: .clineSessionCookie) ?? ""
            githubToken = try c.decodeIfPresent(String.self, forKey: .githubToken) ?? ""
            vpsBaseURL = try c.decodeIfPresent(String.self, forKey: .vpsBaseURL)
                ?? "https://status.patronusguardian.org"
            vpsAPIToken = try c.decodeIfPresent(String.self, forKey: .vpsAPIToken) ?? ""
        }
    }

    // MARK: - Single-blob API

    /// Stores all credentials in one Keychain item (replaces any existing blob).
    static func saveAll(_ creds: Credentials) -> Bool {
        guard let data = try? JSONEncoder().encode(creds) else { return false }
        deleteAll()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Loads all credentials from the single Keychain item. Migrates from the legacy
    /// per-field items on first call if the blob does not exist yet.
    static func loadAll() -> Credentials? {
        if let data = loadRaw(account: account) {
            if let creds = try? JSONDecoder().decode(Credentials.self, from: data) {
                return creds
            }
        }
        // Fallback: migrate from legacy per-field items (older app versions).
        if let migrated = migrateFromLegacy() {
            _ = saveAll(migrated)
            deleteLegacy()
            return migrated
        }
        return nil
    }

    static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func hasCredentials() -> Bool {
        guard let creds = loadAll() else { return false }
        return (!creds.sessionCookie.isEmpty && !creds.organizationId.isEmpty)
            || !creds.vpsAPIToken.isEmpty
            || !creds.githubToken.isEmpty
    }

    // MARK: - Internal

    private static func loadRaw(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private static func migrateFromLegacy() -> Credentials? {
        func legacy(_ account: String) -> String? {
            guard let data = loadRaw(account: account) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let orgId = legacy("claude_organization_id")
        let cookie = legacy("claude_session_cookie")
        let orKey = legacy("openrouter_api_key")
        let cline = legacy("cline_session_cookie")
        guard orgId != nil || cookie != nil || orKey != nil || cline != nil else { return nil }
        return Credentials(
            organizationId: orgId ?? "",
            sessionCookie: cookie ?? "",
            openRouterAPIKey: orKey ?? "",
            clineSessionCookie: cline ?? ""
        )
    }

    private static func deleteLegacy() {
        for account in legacyAccounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
