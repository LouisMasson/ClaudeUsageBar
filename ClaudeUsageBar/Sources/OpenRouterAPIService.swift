import Foundation

/// Fetches the authenticated user's OpenRouter credit balance.
///
/// Mirrors the `ClaudeAPIService` pattern (actor + shared singleton) and reuses
/// the same `APIError` type so the UI can surface errors uniformly.
actor OpenRouterAPIService {
    static let shared = OpenRouterAPIService()

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/credits")!

    private init() {}

    func fetchCredits(apiKey: String) async throws -> OpenRouterCredits {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoded = try JSONDecoder().decode(OpenRouterCreditsResponse.self, from: data)
            return decoded.data
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.serverError(httpResponse.statusCode)
        }
    }
}
