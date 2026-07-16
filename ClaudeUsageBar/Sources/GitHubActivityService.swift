import Foundation

struct GitHubActivitySnapshot {
    let username: String
    let displayName: String?
    let totalContributions: Int
    let commits: Int
    let pullRequests: Int
    let issues: Int
    let reviews: Int
    let privateContributions: Int
    let days: [GitHubContributionDay]
    let fetchedAt: Date
}

struct GitHubContributionDay: Identifiable {
    let date: String
    let count: Int

    var id: String { date }
}

enum GitHubActivityError: LocalizedError {
    case tokenUnavailable
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .tokenUnavailable:
            return "Connectez GitHub CLI ou ajoutez un token GitHub dans les réglages."
        case .invalidResponse:
            return "Réponse GitHub invalide."
        case .api(let message):
            return message
        }
    }
}

actor GitHubActivityService {
    static let shared = GitHubActivityService()

    static func fetchSynchronouslyForTesting(configuredToken: String = "") throws -> GitHubActivitySnapshot {
        let semaphore = DispatchSemaphore(value: 0)
        let box = GitHubSnapshotResultBox()
        Task.detached(priority: .utility) {
            do {
                box.store(.success(try await GitHubActivityService.shared.fetchSnapshot(configuredToken: configuredToken)))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 20) == .success else {
            throw GitHubActivityError.invalidResponse
        }
        guard let result = box.load() else {
            throw GitHubActivityError.invalidResponse
        }
        return try result.get()
    }

    func fetchSnapshot(configuredToken: String) async throws -> GitHubActivitySnapshot {
        let token = try GitHubTokenProvider.resolve(configuredToken: configuredToken)
        let interval = dateInterval()
        let query = """
        query($from: DateTime!, $to: DateTime!) {
          viewer {
            login
            name
            contributionsCollection(from: $from, to: $to) {
              contributionCalendar {
                totalContributions
                weeks {
                  contributionDays { date contributionCount }
                }
              }
              totalCommitContributions
              totalIssueContributions
              totalPullRequestContributions
              totalPullRequestReviewContributions
              restrictedContributionsCount
            }
          }
        }
        """
        let body = GitHubGraphQLRequest(
            query: query,
            variables: [
                "from": Self.iso8601.string(from: interval.start),
                "to": Self.iso8601.string(from: interval.end)
            ]
        )

        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudeUsageBar", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubActivityError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw APIError.unauthorized
            }
            throw APIError.serverError(http.statusCode)
        }

        let payload = try JSONDecoder().decode(GitHubGraphQLResponse.self, from: data)
        if let message = payload.errors?.first?.message {
            throw GitHubActivityError.api(message)
        }
        guard let viewer = payload.data?.viewer else {
            throw GitHubActivityError.invalidResponse
        }

        let collection = viewer.contributionsCollection
        let days = collection.contributionCalendar.weeks
            .flatMap(\.contributionDays)
            .sorted { $0.date < $1.date }
            .map { GitHubContributionDay(date: $0.date, count: $0.contributionCount) }

        return GitHubActivitySnapshot(
            username: viewer.login,
            displayName: viewer.name,
            totalContributions: collection.contributionCalendar.totalContributions,
            commits: collection.totalCommitContributions,
            pullRequests: collection.totalPullRequestContributions,
            issues: collection.totalIssueContributions,
            reviews: collection.totalPullRequestReviewContributions,
            privateContributions: collection.restrictedContributionsCount,
            days: days,
            fetchedAt: Date()
        )
    }

    private func dateInterval(now: Date = Date()) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        return (start, now)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private final class GitHubSnapshotResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<GitHubActivitySnapshot, Error>?

    func store(_ result: Result<GitHubActivitySnapshot, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<GitHubActivitySnapshot, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private enum GitHubTokenProvider {
    private static var cachedCLIToken: String?
    private static let lock = NSLock()

    static func resolve(configuredToken: String) throws -> String {
        let configured = configuredToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }

        lock.lock()
        if let cachedCLIToken {
            lock.unlock()
            return cachedCLIToken
        }
        lock.unlock()

        guard let executable = githubCLIURL() else {
            throw GitHubActivityError.tokenUnavailable
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["auth", "token"]
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw GitHubActivityError.tokenUnavailable
        }
        guard process.terminationStatus == 0 else {
            throw GitHubActivityError.tokenUnavailable
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw GitHubActivityError.tokenUnavailable
        }

        lock.lock()
        cachedCLIToken = token
        lock.unlock()
        return token
    }

    private static func githubCLIURL() -> URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }.map(URL.init(fileURLWithPath:))
    }
}

private struct GitHubGraphQLRequest: Encodable {
    let query: String
    let variables: [String: String]
}

private struct GitHubGraphQLResponse: Decodable {
    let data: DataContainer?
    let errors: [GraphQLError]?

    struct DataContainer: Decodable {
        let viewer: Viewer
    }

    struct GraphQLError: Decodable {
        let message: String
    }
}

private struct Viewer: Decodable {
    let login: String
    let name: String?
    let contributionsCollection: ContributionsCollection
}

private struct ContributionsCollection: Decodable {
    let contributionCalendar: ContributionCalendar
    let totalCommitContributions: Int
    let totalIssueContributions: Int
    let totalPullRequestContributions: Int
    let totalPullRequestReviewContributions: Int
    let restrictedContributionsCount: Int
}

private struct ContributionCalendar: Decodable {
    let totalContributions: Int
    let weeks: [ContributionWeek]
}

private struct ContributionWeek: Decodable {
    let contributionDays: [ContributionDay]
}

private struct ContributionDay: Decodable {
    let date: String
    let contributionCount: Int
}
