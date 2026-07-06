import Foundation

/// Fetches the authenticated user's Cline Pass usage limits (5-hour rolling window,
/// weekly, and monthly).
///
/// Mirrors the `ClaudeAPIService` / `OpenRouterAPIService` pattern (actor + shared
/// singleton) and reuses the same `APIError` type so the UI can surface errors uniformly.
///
/// Endpoint: `GET https://api.cline.bot/api/v1/users/me/plan/usage-limits`
/// Auth: session cookie (`cline_session_id=...`) sent via the `Cookie` header — the same
/// mechanism the web dashboard at app.cline.bot uses. The cookie is stored securely in
/// the macOS Keychain (see `KeychainHelper.Credentials.clineSessionCookie`).
actor ClineAPIService {
    static let shared = ClineAPIService()

    private let endpoint = URL(string: "https://api.cline.bot/api/v1/users/me/plan/usage-limits")!

    private init() {}

    func fetchUsage(sessionCookie: String) async throws -> ClineUsageResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://app.cline.bot", forHTTPHeaderField: "Origin")
        request.setValue("https://app.cline.bot/", forHTTPHeaderField: "Referer")
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            do {
                return try decoder.decode(ClineUsageResponse.self, from: data)
            } catch {
                // Dump the raw body + decoding error to stderr so users running
                // from the terminal can see what cline.bot actually returned
                // when the shape changes.
                let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8 body, \(data.count) bytes>"
                FileHandle.standardError.write(Data("""
                [ClineAPIService] JSON decode failed: \(error)
                [ClineAPIService] Raw response body:
                \(rawBody)

                """.utf8))
                throw APIError.decodingError(ClaudeAPIService.describe(decodingError: error))
            }
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.serverError(httpResponse.statusCode)
        }
    }
}