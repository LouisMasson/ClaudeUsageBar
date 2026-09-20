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

/// A Vercel project the user chose to track. Persisted in UserDefaults
/// (non-secret) so the list can be edited freely from the settings.
struct TrackedVercelProject: Codable, Identifiable, Equatable {
    let projectID: String
    let name: String
    let slug: String

    var id: String { projectID }

    var dashboardURL: URL? {
        URL(string: "https://vercel.com/\(VercelAnalyticsService.teamSlug)/\(slug)/analytics")
    }

    static let hotelRadar = TrackedVercelProject(
        projectID: "prj_oiJDV4EyjMJnJWWLmdC82Unmrq77",
        name: "Hotel Radar",
        slug: "hotel-radar-landing"
    )

    static let theCatalogue = TrackedVercelProject(
        projectID: "prj_1wOHuhWmG5FEyTfs6WtiQuKnrrRx",
        name: "The Catalogue",
        slug: "currated-product"
    )

    /// Seeded on first launch so the existing dashboards keep working.
    static let defaults: [TrackedVercelProject] = [.hotelRadar, .theCatalogue]
}

/// A project discovered through the Vercel API, offered in the settings picker.
struct VercelProjectOption: Identifiable, Equatable {
    let projectID: String
    let name: String
    var id: String { projectID }
}

enum VercelTrackedProjectsStore {
    static let key = "vercelTrackedProjects"

    static func load(defaults: UserDefaults = .standard) -> [TrackedVercelProject] {
        guard let data = defaults.data(forKey: key) else { return TrackedVercelProject.defaults }
        return (try? JSONDecoder().decode([TrackedVercelProject].self, from: data))
            ?? TrackedVercelProject.defaults
    }

    static func save(_ projects: [TrackedVercelProject], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        defaults.set(data, forKey: key)
    }
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

private struct VercelProjectsResponse: Decodable {
    let projects: [VercelProjectDTO]
}

private struct VercelProjectDTO: Decodable {
    let id: String
    let name: String
}

private struct VercelErrorResponse: Decodable {
    struct Inner: Decodable {
        let code: String?
        let message: String?
    }
    let error: Inner
}

actor VercelAnalyticsService {
    static let shared = VercelAnalyticsService()

    static let teamID = "team_cpxCivfFxF9mxxvfAnjXFaNN"
    static let teamSlug = "louis-massons-projects"

    private let endpoint = URL(
        string: "https://api.vercel.com/v1/query/web-analytics/visits/count"
    )!
    private let projectsEndpoint = URL(string: "https://api.vercel.com/v9/projects")!

    func fetchAnalytics(
        projectID: String,
        token: String,
        now: Date = Date()
    ) async throws -> VercelAnalyticsSnapshot {
        let calendar = Calendar.autoupdatingCurrent
        let startOfToday = calendar.startOfDay(for: now)
        let startOfSevenDays = calendar.date(byAdding: .day, value: -6, to: startOfToday)!
        let startOfThirtyDays = calendar.date(byAdding: .day, value: -29, to: startOfToday)!

        async let today = fetchCount(
            projectID: projectID, token: token, since: startOfToday, until: now
        )
        async let sevenDays = fetchCount(
            projectID: projectID, token: token, since: startOfSevenDays, until: now
        )
        async let thirtyDays = fetchCount(
            projectID: projectID, token: token, since: startOfThirtyDays, until: now
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

    /// Lists every project visible to the token within the team, for the picker.
    func fetchProjects(token: String) async throws -> [VercelProjectOption] {
        var components = URLComponents(url: projectsEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "teamId", value: Self.teamID),
            URLQueryItem(name: "limit", value: "100")
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
            let decoded = try JSONDecoder().decode(VercelProjectsResponse.self, from: data)
            return decoded.projects
                .map { VercelProjectOption(projectID: $0.id, name: $0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.serverError(http.statusCode)
        }
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
            // Vercel answers 400 (web_analytics_not_enabled) — and 404 on some
            // teams — when Web Analytics is off for the project.
            let apiError = try? JSONDecoder().decode(VercelErrorResponse.self, from: data)
            if apiError?.error.code == "web_analytics_not_enabled" || http.statusCode == 404 {
                throw APIError.notEnabled("Web Analytics non activé")
            }
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