import Foundation

// MARK: - API Response Models

struct UsageResponse: Codable {
    let fiveHour: UsageLimit?
    let sevenDay: UsageLimit?
    let sevenDaySonnet: UsageLimit?
    let sevenDayOmelette: UsageLimit?  // Claude Design
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOmelette = "seven_day_omelette"
        case extraUsage = "extra_usage"
    }
}

struct UsageLimit: Codable {
    let utilization: Int
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt)
    }

    var timeUntilReset: String {
        guard let resetDate = resetDate else { return "N/A" }
        let interval = resetDate.timeIntervalSinceNow

        if interval <= 0 {
            return "Now"
        }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "\(days)j \(remainingHours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)min"
        } else {
            return "\(minutes) min"
        }
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool
    let monthlyLimit: Int
    let usedCredits: Int
    let utilization: Double

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

// MARK: - OpenRouter Models

struct OpenRouterCreditsResponse: Codable {
    let data: OpenRouterCredits
}

struct OpenRouterCredits: Codable {
    let totalCredits: Double
    let totalUsage: Double

    enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }

    var remaining: Double { max(0, totalCredits - totalUsage) }

    var utilization: Int {
        guard totalCredits > 0 else { return 0 }
        return min(100, Int((totalUsage / totalCredits) * 100))
    }
}

// MARK: - App State

class SettingsState: ObservableObject {
    static let notchOverlayKey = "notchOverlayEnabled"

    @Published var orgId: String = ""
    @Published var cookie: String = ""
    @Published var openRouterKey: String = ""
    @Published var notchOverlayEnabled: Bool = UserDefaults.standard.bool(forKey: SettingsState.notchOverlayKey)
}

@MainActor
class UsageState: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastUpdated: Date?

    @Published var openRouterCredits: OpenRouterCredits?
    @Published var openRouterError: String?

    var sessionUtilization: Int {
        usage?.fiveHour?.utilization ?? 0
    }

    var sessionResetTime: String {
        usage?.fiveHour?.timeUntilReset ?? "N/A"
    }

    var weeklyUtilization: Int {
        usage?.sevenDay?.utilization ?? 0
    }

    var weeklyResetTime: String {
        usage?.sevenDay?.timeUntilReset ?? "N/A"
    }

    var sonnetUtilization: Int {
        usage?.sevenDaySonnet?.utilization ?? 0
    }

    var designUtilization: Int {
        usage?.sevenDayOmelette?.utilization ?? 0
    }

    var openRouterUtilization: Int {
        openRouterCredits?.utilization ?? 0
    }

    var openRouterRemainingLabel: String {
        guard let credits = openRouterCredits else { return "—" }
        return String(format: "$%.2f restants", credits.remaining)
    }

    var openRouterTotalLabel: String {
        guard let credits = openRouterCredits else { return "" }
        return String(format: "$%.2f / $%.2f", credits.totalUsage, credits.totalCredits)
    }
}
