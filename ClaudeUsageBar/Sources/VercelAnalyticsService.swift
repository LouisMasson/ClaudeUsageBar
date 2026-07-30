import Foundation

struct WebsiteAnalyticsPeriod: Equatable {
    let visitors: Int
    let pageviews: Int
}

struct WebsiteAnalyticsMetrics: Equatable {
    let today: WebsiteAnalyticsPeriod
    let sevenDays: WebsiteAnalyticsPeriod
    let thirtyDays: WebsiteAnalyticsPeriod
}

struct VercelAnalyticsSnapshot: Equatable {
    let metrics: WebsiteAnalyticsMetrics
    let fetchedAt: Date
}

struct VercelAnalyticsSite: Equatable {
    let projectID: String
    let displayName: String
    let domain: String
    let dashboardURL: URL

    static let hotelRadar = VercelAnalyticsSite(
        projectID: "prj_oiJDV4EyjMJnJWWLmdC82Unmrq77",
        displayName: "Hotel Radar",
        domain: "hotel-radar-landing.vercel.app",
        dashboardURL: URL(
            string: "https://vercel.com/louis-massons-projects/hotel-radar-landing/analytics"
        )!
    )

    static let theCatalogue = VercelAnalyticsSite(
        projectID: "prj_1wOHuhWmG5FEyTfs6WtiQuKnrrRx",
        displayName: "The Catalogue",
        domain: "thecatalogue.studio",
        dashboardURL: URL(
            string: "https://vercel.com/louis-massons-projects/currated-product/analytics"
        )!
    )
}

private struct VercelVisitCountResponse: Decodable {
    let data: VercelVisitCount
}

private struct VercelVisitCount: Decodable {
    let visitors: Int
    let pageviews: Int

    var websitePeriod: WebsiteAnalyticsPeriod {
        WebsiteAnalyticsPeriod(visitors: visitors, pageviews: pageviews)
    }
}

actor VercelAnalyticsService {
    static let shared = VercelAnalyticsService()

    static let teamID = "team_cpxCivfFxF9mxxvfAnjXFaNN"

    private let endpoint = URL(
        string: "https://api.vercel.com/v1/query/web-analytics/visits/count"
    )!

    func fetchAnalytics(
        for site: VercelAnalyticsSite,
        token: String,
        now: Date = Date()
    ) async throws -> VercelAnalyticsSnapshot {
        let calendar = Calendar.autoupdatingCurrent
        let startOfToday = calendar.startOfDay(for: now)
        let startOfSevenDays = calendar.date(byAdding: .day, value: -6, to: startOfToday)!
        let startOfThirtyDays = calendar.date(byAdding: .day, value: -29, to: startOfToday)!

        async let today = fetchCount(
            projectID: site.projectID, token: token, since: startOfToday, until: now
        )
        async let sevenDays = fetchCount(
            projectID: site.projectID, token: token, since: startOfSevenDays, until: now
        )
        async let thirtyDays = fetchCount(
            projectID: site.projectID, token: token, since: startOfThirtyDays, until: now
        )

        return try await VercelAnalyticsSnapshot(
            metrics: WebsiteAnalyticsMetrics(
                today: today.websitePeriod,
                sevenDays: sevenDays.websitePeriod,
                thirtyDays: thirtyDays.websitePeriod
            ),
            fetchedAt: now
        )
    }

    private func fetchCount(
        projectID: String,
        token: String,
        since: Date,
        until: Date
    ) async throws -> VercelVisitCount {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        components.queryItems = [
            URLQueryItem(name: "projectId", value: projectID),
            URLQueryItem(name: "teamId", value: Self.teamID),
            URLQueryItem(name: "since", value: formatter.string(from: since)),
            URLQueryItem(name: "until", value: formatter.string(from: until))
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(VercelVisitCountResponse.self, from: data).data
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.serverError(http.statusCode)
        }
    }
}

extension VPSPlausibleAnalytics {
    var websiteMetrics: WebsiteAnalyticsMetrics {
        WebsiteAnalyticsMetrics(
            today: WebsiteAnalyticsPeriod(
                visitors: today.visitors,
                pageviews: today.pageviews
            ),
            sevenDays: WebsiteAnalyticsPeriod(
                visitors: sevenDays.visitors,
                pageviews: sevenDays.pageviews
            ),
            thirtyDays: WebsiteAnalyticsPeriod(
                visitors: thirtyDays.visitors,
                pageviews: thirtyDays.pageviews
            )
        )
    }
}
