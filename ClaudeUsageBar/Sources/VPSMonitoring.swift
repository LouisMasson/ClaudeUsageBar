import Foundation

struct VPSMenuStatus: Codable {
    let schemaVersion: Int
    let status: String
    let updatedAt: String
    let vps: VPSResources
    let sites: VPSAvailability
    let services: VPSAvailability

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status
        case updatedAt = "updated_at"
        case vps, sites, services
    }

    var isHealthy: Bool { status == "ok" }
}

struct VPSResources: Codable {
    let cpuPercent: Double
    let ramPercent: Double
    let ramAvailableGB: Double?
    let swapPercent: Double?
    let swapUsedGB: Double?
    let diskPercent: Double
    let diskFreeGB: Double?
    let load1: Double?
    let load5: Double?
    let load15: Double?
    let cores: Int?
    let uptime: String

    enum CodingKeys: String, CodingKey {
        case cpuPercent = "cpu_percent"
        case ramPercent = "ram_percent"
        case ramAvailableGB = "ram_available_gb"
        case swapPercent = "swap_percent"
        case swapUsedGB = "swap_used_gb"
        case diskPercent = "disk_percent"
        case diskFreeGB = "disk_free_gb"
        case load1 = "load_1"
        case load5 = "load_5"
        case load15 = "load_15"
        case cores
        case uptime
    }
}

struct VPSAvailability: Codable {
    let healthy: Int
    let total: Int
    let items: [VPSAvailabilityItem]
}

struct VPSAvailabilityItem: Codable, Identifiable {
    let name: String
    let status: String
    let detail: String?
    let url: String?
    let httpStatus: Int?
    let latencyMS: Int?
    let tlsDaysRemaining: Int?
    let image: String?
    let createdAt: String?
    let analytics: VPSPlausibleAnalytics?

    enum CodingKeys: String, CodingKey {
        case name, status, detail, url, image, analytics
        case httpStatus = "http_status"
        case latencyMS = "latency_ms"
        case tlsDaysRemaining = "tls_days_remaining"
        case createdAt = "created_at"
    }

    var id: String { name }
    var isHealthy: Bool { status == "up" || status == "running" }
}

struct VPSPlausibleAnalytics: Codable {
    let today: VPSPlausibleAggregate
    let sevenDays: VPSPlausibleAggregate
    let thirtyDays: VPSPlausibleAggregate

    enum CodingKeys: String, CodingKey {
        case today
        case sevenDays = "7d"
        case thirtyDays = "30d"
    }
}

struct VPSPlausibleAggregate: Codable {
    let visitors: Int
    let visits: Int
    let pageviews: Int
}

struct VPSHistorySample: Codable, Identifiable {
    let timestamp: Date
    let cpu: Double
    let ram: Double
    let disk: Double

    var id: Date { timestamp }
}

actor VPSAPIService {
    static let shared = VPSAPIService()

    func fetchStatus(baseURL: String, token: String) async throws -> VPSMenuStatus {
        let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: normalized + "/api/menu-status") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(VPSMenuStatus.self, from: data)
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.serverError(http.statusCode)
        }
    }
}

enum VPSHistoryStore {
    private static let retention: TimeInterval = 7 * 24 * 3600
    private static let queue = DispatchQueue(label: "com.louismasson.ClaudeUsageBar.vps-history", qos: .utility)

    static func load() -> [VPSHistorySample] {
        guard let data = try? Data(contentsOf: fileURL),
              let samples = try? JSONDecoder().decode([VPSHistorySample].self, from: data) else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-retention)
        return samples.filter { $0.timestamp >= cutoff }
    }

    static func append(_ sample: VPSHistorySample, to current: [VPSHistorySample]) -> [VPSHistorySample] {
        let cutoff = sample.timestamp.addingTimeInterval(-retention)
        let updated = (current + [sample]).filter { $0.timestamp >= cutoff }
        let snapshot = updated
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: fileURL, options: .atomic)
        }
        return updated
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ClaudeUsageBar", isDirectory: true)
            .appendingPathComponent("vps-history.json")
    }
}
