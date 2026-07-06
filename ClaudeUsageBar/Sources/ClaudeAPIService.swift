import Foundation

actor ClaudeAPIService {
    static let shared = ClaudeAPIService()

    private let baseURL = "https://claude.ai/api/organizations"

    private init() {}

    func fetchUsage(organizationId: String, sessionKey: String) async throws -> UsageResponse {
        let urlString = "\(baseURL)/\(organizationId)/usage"

        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL
        }

        return try await NetworkRetry.retry {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
            request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
            request.setValue(sessionKey, forHTTPHeaderField: "Cookie")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                do {
                    return try decoder.decode(UsageResponse.self, from: data)
                } catch {
                    // Dump the raw body + decoding error to stderr so users running
                    // from the terminal can see what claude.ai actually returned
                    // when the shape changes.
                    let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8 body, \(data.count) bytes>"
                    FileHandle.standardError.write(Data("""
                    [ClaudeAPIService] JSON decode failed: \(error)
                    [ClaudeAPIService] Raw response body:
                    \(rawBody)

                    """.utf8))
                    throw APIError.decodingError(Self.describe(decodingError: error))
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

    /// Turns a `DecodingError` into a short, user-friendly string (the default
    /// `localizedDescription` is just "The data couldn't be read because it is
    /// missing", which hides the actual problem).
    ///
    /// Internal (not private) so the other API services (`ClineAPIService`) can reuse
    /// the exact same diagnostic formatting instead of duplicating it.
    static func describe(decodingError error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decodingError {
        case .keyNotFound(let key, let ctx):
            return "clé manquante \"\(key.stringValue)\" — \(ctx.debugDescription)"
        case .valueNotFound(let type, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return "valeur \(type) nulle à \"\(path)\""
        case .typeMismatch(let type, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return "type \(type) attendu à \"\(path)\""
        case .dataCorrupted(let ctx):
            return "données corrompues — \(ctx.debugDescription)"
        @unknown default:
            return decodingError.localizedDescription
        }
    }
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case rateLimited
    case serverError(Int)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "URL invalide"
        case .invalidResponse:
            return "Reponse invalide du serveur"
        case .unauthorized:
            return "Session expiree - Mettez a jour vos cookies"
        case .rateLimited:
            return "Claude limite temporairement les requetes — nouvel essai dans 5 min"
        case .serverError(let code):
            return "Erreur serveur: \(code)"
        case .decodingError(let message):
            return "Erreur de decodage: \(message)"
        }
    }
}

// MARK: - Network Retry Helper

/// Retries a throwing async operation with exponential backoff.
///
/// Shared by all API services. Only retries on **transient** errors:
/// - `URLError` (no connection, timeout, DNS failure, etc.)
/// - `APIError.serverError` with 5xx status codes
/// - `APIError.invalidResponse`
///
/// Does **not** retry on:
/// - `APIError.unauthorized` (401/403 — cookie expired, no point retrying)
/// - `APIError.rateLimited` (429 — retrying would make it worse)
/// - `APIError.decodingError` (response structure changed — needs a code fix)
/// - `APIError.invalidURL` (malformed URL — needs a config fix)
enum NetworkRetry {
    /// Executes `operation`, retrying up to `maxAttempts` times with delays from
    /// `backoff` (e.g. `[2, 5]` → 2s after 1st failure, 5s after 2nd). The final
    /// error is re-thrown if all attempts fail.
    static func retry<T>(
        maxAttempts: Int = 3,
        backoff: [TimeInterval] = [2, 5],
        _ operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                guard isRetryable(error), attempt < maxAttempts - 1 else {
                    throw error
                }
                let delay = attempt < backoff.count ? backoff[attempt] : (backoff.last ?? 5)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? APIError.invalidResponse
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .serverError(let code): return code >= 500
            case .invalidResponse:       return true
            case .unauthorized, .rateLimited, .decodingError, .invalidURL:
                return false
            }
        }
        return false
    }
}
