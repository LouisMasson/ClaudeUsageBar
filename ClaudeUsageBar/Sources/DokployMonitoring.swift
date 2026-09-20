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

// MARK: - Project overview (/api/project.all)

enum DokployServiceKind: String {
    case application
    case compose
    case database

    var symbol: String {
        switch self {
        case .application: return "app"
        case .compose: return "square.stack.3d.up"
        case .database: return "cylinder"
        }
    }
}

enum DokployServiceStatus {
    case healthy
    case deploying
    case error
    case unknown

    var label: String {
        switch self {
        case .healthy: return "actif"
        case .deploying: return "déploiement"
        case .error: return "erreur"
        case .unknown: return "inconnu"
        }
    }

    static func from(_ raw: String?) -> DokployServiceStatus {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return .unknown }
        switch raw {
        case "error", "failed", "crash", "crashed":
            return .error
        case "running", "deploying", "queued", "starting", "building":
            return .deploying
        case "done", "healthy", "success", "succeeded":
            return .healthy
        default:
            return .unknown
        }
    }
}

struct DokployServiceSummary: Identifiable {
    let name: String
    let status: DokployServiceStatus
    let kind: DokployServiceKind

    var id: String { "\(kind.rawValue)-\(name)" }
}

struct DokployEnvironmentSummary: Decodable {
    let name: String
    let services: [DokployServiceSummary]

    private enum CodingKeys: String, CodingKey {
        case name, applications, compose, mariadb, mongo, mysql, postgres, redis, libsql
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? "production"

        func decodeServices(_ key: CodingKeys, kind: DokployServiceKind) -> [DokployServiceSummary] {
            guard let raw = try? container.decode([DokployRawService].self, forKey: key) else {
                return []
            }
            return raw.map {
                DokployServiceSummary(
                    name: $0.name,
                    status: DokployServiceStatus.from($0.status),
                    kind: kind
                )
            }
        }

        var collected: [DokployServiceSummary] = []
        collected += decodeServices(.applications, kind: .application)
        collected += decodeServices(.compose, kind: .compose)
        collected += decodeServices(.postgres, kind: .database)
        collected += decodeServices(.mysql, kind: .database)
        collected += decodeServices(.mariadb, kind: .database)
        collected += decodeServices(.mongo, kind: .database)
        collected += decodeServices(.redis, kind: .database)
        collected += decodeServices(.libsql, kind: .database)
        services = collected
    }
}

struct DokployProjectSummary: Decodable, Identifiable {
    let projectId: String
    let name: String
    let description: String?
    let environments: [DokployEnvironmentSummary]

    var id: String { projectId }
    var services: [DokployServiceSummary] { environments.flatMap(\.services) }
    var hasError: Bool { services.contains { $0.status == .error } }
    var isDeploying: Bool { services.contains { $0.status == .deploying } }

    private enum CodingKeys: String, CodingKey {
        case projectId, name, description, environments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectId = (try? container.decode(String.self, forKey: .projectId)) ?? UUID().uuidString
        name = (try? container.decode(String.self, forKey: .name)) ?? "Projet"
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        environments = (try? container.decode([DokployEnvironmentSummary].self, forKey: .environments)) ?? []
    }
}

/// Tolerant decoder: service payloads use a different status key per kind
/// (`applicationStatus`, `composeStatus`, …) so we sniff the first one present.
private struct DokployRawService: Decodable {
    let name: String
    let status: String?

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.intValue = intValue; self.stringValue = "\(intValue)" }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        func key(_ value: String) -> DynamicKey? { DynamicKey(stringValue: value) }

        name = (try? container.decode(String.self, forKey: key("name") ?? DynamicKey(stringValue: "name")!)) ?? "service"

        let candidates = [
            "applicationStatus", "composeStatus", "databaseStatus",
            "mariadbStatus", "mongoStatus", "mysqlStatus",
            "postgresStatus", "redisStatus", "libsqlStatus", "status"
        ]
        var resolved: String?
        for candidate in candidates {
            guard let codingKey = key(candidate) else { continue }
            guard let value = (try? container.decodeIfPresent(String.self, forKey: codingKey)) ?? nil,
                  !value.isEmpty else { continue }
            resolved = value
            break
        }
        status = resolved
    }
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

    func fetchProjects(baseURL: String, apiKey: String) async throws -> [DokployProjectSummary] {
        let normalized = normalizedBaseURL(baseURL)
        guard let url = URL(string: normalized + "/api/project.all") else {
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
            return try JSONDecoder().decode([DokployProjectSummary].self, from: data)
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
