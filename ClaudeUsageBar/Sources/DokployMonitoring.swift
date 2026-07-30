import Foundation

struct DokployDeployment: Decodable, Identifiable {
    let deploymentId: String
    let title: String
    let description: String?
    let status: String
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?
    let errorMessage: String?
    let application: DokployService?
    let compose: DokployService?

    var id: String { deploymentId }
    var service: DokployService? { application ?? compose }
    var isTerminal: Bool {
        status == "done" || status == "error" || status == "cancelled"
    }
    var isSuccessful: Bool { status == "done" }

    private enum CodingKeys: String, CodingKey {
        case deploymentId, title, description, status, createdAt, startedAt, finishedAt
        case errorMessage, application, compose
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deploymentId = try container.decode(String.self, forKey: .deploymentId)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Déploiement"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "running"
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(String.self, forKey: .finishedAt)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        application = try container.decodeIfPresent(DokployService.self, forKey: .application)
        compose = try container.decodeIfPresent(DokployService.self, forKey: .compose)
    }
}

struct DokployService: Decodable {
    let name: String
    let environment: DokployEnvironment?
}

struct DokployEnvironment: Decodable {
    let name: String
    let project: DokployProject?
}

struct DokployProject: Decodable {
    let name: String
}

actor DokployAPIService {
    static let shared = DokployAPIService()

    func fetchDeployments(baseURL: String, apiKey: String) async throws -> [DokployDeployment] {
        let normalized = normalizedBaseURL(baseURL)
        guard let url = URL(string: normalized + "/api/deployment.allCentralized") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode([DokployDeployment].self, from: data)
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.serverError(http.statusCode)
        }
    }

    private func normalizedBaseURL(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.hasSuffix("/api") ? String(trimmed.dropLast(4)) : trimmed
    }
}

enum DokployDeploymentTracker {
    private static let maxRememberedDeployments = 500

    /// Returns terminal deployments that have not been reported yet.
    /// The first sync only creates a baseline so existing history is not replayed.
    static func newlyFinished(
        _ deployments: [DokployDeployment],
        baseURL: String,
        defaults: UserDefaults = .standard
    ) -> [DokployDeployment] {
        let namespace = Data(normalized(baseURL).utf8).base64EncodedString()
        let notifiedKey = "notifiedDokployDeploymentIDs.\(namespace)"
        let bootstrappedKey = "dokployDeploymentMonitorBootstrapped.\(namespace)"
        let terminal = deployments.filter(\.isTerminal)

        var notified = defaults.stringArray(forKey: notifiedKey) ?? []
        let isBootstrapped = defaults.bool(forKey: bootstrappedKey)
        var notifiedSet = Set(notified)
        let newDeployments = isBootstrapped
            ? terminal.filter { !notifiedSet.contains($0.deploymentId) }
            : []

        for deployment in terminal where !notifiedSet.contains(deployment.deploymentId) {
            notified.append(deployment.deploymentId)
            notifiedSet.insert(deployment.deploymentId)
        }
        if notified.count > maxRememberedDeployments {
            notified.removeFirst(notified.count - maxRememberedDeployments)
        }
        defaults.set(notified, forKey: notifiedKey)
        defaults.set(true, forKey: bootstrappedKey)
        return newDeployments
    }

    private static func normalized(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return trimmed.hasSuffix("/api") ? String(trimmed.dropLast(4)) : trimmed
    }
}
