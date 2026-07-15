import Foundation

/// Fetches the authenticated user's OpenRouter credit balance.
///
/// Mirrors the `ClaudeAPIService` pattern (actor + shared singleton) and reuses
/// the same `APIError` type so the UI can surface errors uniformly.
actor OpenRouterAPIService {
    static let shared = OpenRouterAPIService()

    private let creditsEndpoint = URL(string: "https://openrouter.ai/api/v1/credits")!
    private let analyticsEndpoint = URL(string: "https://openrouter.ai/api/v1/analytics/query")!

    private init() {}

    func fetchCredits(apiKey: String) async throws -> OpenRouterCredits {
        try await NetworkRetry.retry {
            var request = URLRequest(url: creditsEndpoint)
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

    func fetchActivitySnapshot(apiKey: String) async throws -> OpenRouterActivitySnapshot {
        let overview = try await queryAnalytics(apiKey: apiKey, dimension: nil)
        async let models = try? queryAnalytics(apiKey: apiKey, dimension: "model")
        async let apps = try? queryAnalytics(apiKey: apiKey, dimension: "app")
        async let keys = try? queryAnalytics(apiKey: apiKey, dimension: "api_key_id")

        let overviewItems = overview.compactMap { row -> OpenRouterActivityItem? in
            guard !row.date.isEmpty else { return nil }
            return OpenRouterActivityItem(
                byokUsageInference: 0,
                completionTokens: 0,
                date: row.date,
                endpointID: nil,
                model: "",
                modelPermaslug: nil,
                promptTokens: row.tokens,
                providerName: "",
                reasoningTokens: row.reasoningTokens,
                requests: row.requests,
                usage: row.spend
            )
        }
        let cacheRates = Dictionary(
            uniqueKeysWithValues: overview.compactMap { row in
                row.cacheHitRate.map { (row.date, $0) }
            }
        )

        return OpenRouterActivitySnapshot(
            items: overviewItems,
            cacheHitRates: cacheRates,
            modelActivities: Self.dimensionActivities(await models ?? [], dimension: "model"),
            appActivities: Self.dimensionActivities(await apps ?? [], dimension: "app"),
            keyActivities: Self.dimensionActivities(await keys ?? [], dimension: "api_key_id"),
            fetchedAt: Date()
        )
    }

    private func queryAnalytics(apiKey: String, dimension: String?) async throws -> [OpenRouterAnalyticsRow] {
        try await NetworkRetry.retry {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let end = calendar.startOfDay(for: Date())
            let start = calendar.date(byAdding: .day, value: -60, to: end)!
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]

            var body: [String: Any] = [
                "metrics": ["total_usage", "request_count", "tokens_total", "reasoning_tokens", "cache_hit_rate"],
                "granularity": "day",
                "time_range": ["start": formatter.string(from: start), "end": formatter.string(from: end)],
                "limit": 5000
            ]
            if let dimension { body["dimensions"] = [dimension] }

            var request = URLRequest(url: analyticsEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            switch httpResponse.statusCode {
            case 200:
                return try JSONDecoder().decode(OpenRouterAnalyticsResponse.self, from: data).data.data
            case 401, 403:
                throw OpenRouterActivityError.managementKeyRequired
            case 429:
                throw APIError.rateLimited
            default:
                throw APIError.serverError(httpResponse.statusCode)
            }
        }
    }

    private static func dimensionActivities(
        _ rows: [OpenRouterAnalyticsRow],
        dimension: String
    ) -> [OpenRouterDimensionActivity] {
        rows.compactMap { row in
            guard !row.date.isEmpty else { return nil }
            let name = row.dimensionValue(for: dimension).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown"
            return OpenRouterDimensionActivity(
                date: row.date,
                name: name,
                spend: row.spend,
                requests: row.requests,
                tokens: row.tokens
            )
        }
    }
}

enum OpenRouterActivityError: LocalizedError {
    case managementKeyRequired

    var errorDescription: String? {
        switch self {
        case .managementKeyRequired:
            return "Une clé de gestion OpenRouter est requise pour afficher l’activité."
        }
    }
}

struct OpenRouterAnalyticsResponse: Decodable {
    let data: OpenRouterAnalyticsPayload
}

struct OpenRouterAnalyticsPayload: Decodable {
    let data: [OpenRouterAnalyticsRow]
}

struct OpenRouterAnalyticsRow: Decodable {
    let date: String
    let spend: Double
    let requests: Int
    let tokens: Int
    let reasoningTokens: Int
    let cacheHitRate: Double?
    let model: String?
    let app: String?
    let apiKeyID: String?

    enum CodingKeys: String, CodingKey {
        case dateDay = "date__day"
        case createdDay = "created_at__day"
        case spend = "total_usage"
        case requests = "request_count"
        case tokens = "tokens_total"
        case reasoningTokens = "reasoning_tokens"
        case cacheHitRate = "cache_hit_rate"
        case model, app
        case apiKeyID = "api_key_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? container.decodeIfPresent(String.self, forKey: .dateDay))
            ?? (try? container.decodeIfPresent(String.self, forKey: .createdDay))
            ?? ""
        spend = Self.double(container, .spend) ?? 0
        requests = Int(Self.double(container, .requests) ?? 0)
        tokens = Int(Self.double(container, .tokens) ?? 0)
        reasoningTokens = Int(Self.double(container, .reasoningTokens) ?? 0)
        cacheHitRate = Self.double(container, .cacheHitRate)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        app = try? container.decodeIfPresent(String.self, forKey: .app)
        apiKeyID = try? container.decodeIfPresent(String.self, forKey: .apiKeyID)
    }

    func dimensionValue(for dimension: String) -> String? {
        switch dimension {
        case "model": return model
        case "app": return app
        case "api_key_id": return apiKeyID
        default: return nil
        }
    }

    private static func double(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }
}
