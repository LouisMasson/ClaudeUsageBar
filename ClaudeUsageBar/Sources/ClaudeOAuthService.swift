import Foundation
import LocalAuthentication
import Security

struct ClaudeCodeOAuthCredentials: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Double?
    let scopes: [String]?
}

private struct ClaudeCodeCredentialsEnvelope: Decodable {
    let claudeAiOauth: ClaudeCodeOAuthCredentials
}

enum ClaudeOAuthError: LocalizedError {
    case credentialsUnavailable

    var errorDescription: String? {
        "Connexion Claude Code indisponible — ouvrez les réglages pour l’autoriser."
    }
}

actor ClaudeOAuthService {
    static let shared = ClaudeOAuthService()
    private static let keychainService = "Claude Code-credentials"

    /// Background reads explicitly disable authentication UI. This guarantees that
    /// starting or refreshing the app can never display a Keychain prompt.
    static func loadCredentials(allowPrompt: Bool) throws -> ClaudeCodeOAuthCredentials {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if !allowPrompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClaudeOAuthError.credentialsUnavailable
        }
        return try JSONDecoder().decode(ClaudeCodeCredentialsEnvelope.self, from: data).claudeAiOauth
    }

    func fetchUsage(accessToken: String) async throws -> UsageResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/2.0.76", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.serverError(http.statusCode)
        }
    }
}
