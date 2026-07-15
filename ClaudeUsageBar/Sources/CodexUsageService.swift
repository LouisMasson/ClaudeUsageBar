import Foundation

struct CodexUsageSnapshot {
    let rateLimits: CodexRateLimitSnapshot
    let tokenUsage: CodexTokenUsageResponse
    let fetchedAt: Date

    var windows: [CodexRateLimitWindow] {
        [rateLimits.primary, rateLimits.secondary].compactMap { $0 }
    }
}

struct CodexRateLimitsResponse: Decodable {
    let rateLimits: CodexRateLimitSnapshot
    let rateLimitsByLimitID: [String: CodexRateLimitSnapshot]?

    enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
    }

    var codex: CodexRateLimitSnapshot { rateLimitsByLimitID?["codex"] ?? rateLimits }
}

struct CodexRateLimitSnapshot: Decodable {
    let limitID: String?
    let limitName: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let credits: CodexCreditsSnapshot?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case limitID = "limitId"
        case limitName, primary, secondary, credits, planType
    }
}

struct CodexCreditsSnapshot: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct CodexRateLimitWindow: Decodable, Identifiable {
    let usedPercent: Int
    let resetsAt: Int?
    let windowDurationMins: Int?

    var id: String { "\(windowDurationMins ?? 0)-\(resetsAt ?? 0)" }

    var label: String {
        guard let minutes = windowDurationMins else { return "Limite" }
        if minutes <= 360 { return "Session \(max(1, minutes / 60))h" }
        if minutes <= 1_440 { return "Journalière" }
        if minutes <= 10_080 { return "Hebdomadaire" }
        return "\(max(1, minutes / 1_440)) jours"
    }

    var resetLabel: String {
        guard let resetsAt else { return "N/A" }
        let interval = Date(timeIntervalSince1970: TimeInterval(resetsAt)).timeIntervalSinceNow
        guard interval > 0 else { return "maintenant" }
        let hours = Int(interval) / 3_600
        let minutes = (Int(interval) % 3_600) / 60
        if hours >= 24 { return "\(hours / 24)j \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes)min" }
        return "\(minutes) min"
    }
}

struct CodexTokenUsageResponse: Decodable {
    let summary: CodexTokenUsageSummary
    let dailyUsageBuckets: [CodexDailyTokenUsage]?
}

struct CodexTokenUsageSummary: Decodable {
    let lifetimeTokens: Int?
    let peakDailyTokens: Int?
    let longestRunningTurnSec: Int?
    let currentStreakDays: Int?
    let longestStreakDays: Int?
}

struct CodexDailyTokenUsage: Decodable, Identifiable {
    let startDate: String
    let tokens: Int
    var id: String { startDate }
}

enum CodexUsageError: LocalizedError {
    case executableUnavailable
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable: return "Codex n’est pas installé sur ce Mac."
        case .invalidResponse: return "Codex a renvoyé une réponse illisible."
        case .server(let message): return message
        }
    }
}

actor CodexUsageService {
    static let shared = CodexUsageService()

    private init() {}

    func fetchUsage() async throws -> CodexUsageSnapshot {
        try await Task.detached(priority: .utility) {
            try Self.fetchSynchronouslyForTesting()
        }.value
    }

    static func fetchSynchronouslyForTesting() throws -> CodexUsageSnapshot {
        guard let executable = codexExecutable() else { throw CodexUsageError.executableUnavailable }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
            if process.isRunning { process.terminate() }
        }

        let reader = RPCLineReader(handle: output.fileHandleForReading)
        try write([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "ai-usage-monitor", "version": "1.1.0"],
                "capabilities": ["experimentalApi": true]
            ]
        ], to: input.fileHandleForWriting)
        _ = try responseResult(id: 1, reader: reader)

        try write(["method": "initialized"], to: input.fileHandleForWriting)
        try write(["id": 2, "method": "account/rateLimits/read", "params": NSNull()], to: input.fileHandleForWriting)
        try write(["id": 3, "method": "account/usage/read", "params": NSNull()], to: input.fileHandleForWriting)

        var rateResult: Any?
        var usageResult: Any?
        while rateResult == nil || usageResult == nil {
            let message = try reader.next()
            guard let id = message["id"] as? Int else { continue }
            if let error = message["error"] as? [String: Any] {
                throw CodexUsageError.server(error["message"] as? String ?? "Erreur Codex")
            }
            if id == 2 { rateResult = message["result"] }
            if id == 3 { usageResult = message["result"] }
        }

        input.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        let decoder = JSONDecoder()
        let rates = try decoder.decode(CodexRateLimitsResponse.self, from: jsonData(rateResult!))
        let usage = try decoder.decode(CodexTokenUsageResponse.self, from: jsonData(usageResult!))
        return CodexUsageSnapshot(rateLimits: rates.codex, tokenUsage: usage, fetchedAt: Date())
    }

    private static func responseResult(id: Int, reader: RPCLineReader) throws -> Any {
        while true {
            let message = try reader.next()
            guard message["id"] as? Int == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw CodexUsageError.server(error["message"] as? String ?? "Erreur Codex")
            }
            guard let result = message["result"] else { throw CodexUsageError.invalidResponse }
            return result
        }
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func jsonData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw CodexUsageError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func codexExecutable() -> String? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private final class RPCLineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) { self.handle = handle }

    func next() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexUsageError.invalidResponse
                }
                return object
            }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { throw CodexUsageError.invalidResponse }
            buffer.append(chunk)
        }
    }
}
