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

    // Tolerate missing / null / differently-typed fields from the claude.ai
    // response (Anthropic has renamed fields before without notice).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intValue = try? c.decodeIfPresent(Int.self, forKey: .utilization) {
            self.utilization = intValue
        } else if let doubleValue = try? c.decodeIfPresent(Double.self, forKey: .utilization) {
            self.utilization = Int(doubleValue)
        } else {
            self.utilization = 0
        }
        self.resetsAt = (try? c.decodeIfPresent(String.self, forKey: .resetsAt)) ?? ""
    }

    // Retain the default synthesized Encodable by explicitly providing encode.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(utilization, forKey: .utilization)
        try c.encode(resetsAt, forKey: .resetsAt)
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false
        self.monthlyLimit = (try? c.decodeIfPresent(Int.self, forKey: .monthlyLimit)) ?? 0
        self.usedCredits = (try? c.decodeIfPresent(Int.self, forKey: .usedCredits)) ?? 0
        self.utilization = (try? c.decodeIfPresent(Double.self, forKey: .utilization)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(monthlyLimit, forKey: .monthlyLimit)
        try c.encode(usedCredits, forKey: .usedCredits)
        try c.encode(utilization, forKey: .utilization)
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

// MARK: - Cline Pass Models

/// Response from `GET https://api.cline.bot/api/v1/users/me/plan/usage-limits`.
/// Cline Pass measures usage against three rolling limits: a 5-hour window, a
/// weekly window, and a monthly window. Each limit exposes the used percentage
/// and its reset timestamp.
struct ClineUsageResponse: Codable {
    let data: ClineUsageData
    let success: Bool
}

struct ClineUsageData: Codable {
    let limits: [ClineLimit]
}

struct ClineLimit: Codable {
    let type: String          // "five_hour" | "weekly" | "monthly"
    let percentUsed: Int
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case type
        case percentUsed = "percentUsed"
        case resetsAt = "resetsAt"
    }

    // Tolerate missing / null / differently-typed fields from the cline.bot
    // response (mirror of the defensive decoding used for Anthropic's `UsageLimit`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        if let intValue = try? c.decodeIfPresent(Int.self, forKey: .percentUsed) {
            self.percentUsed = intValue
        } else if let doubleValue = try? c.decodeIfPresent(Double.self, forKey: .percentUsed) {
            self.percentUsed = Int(doubleValue)
        } else {
            self.percentUsed = 0
        }
        self.resetsAt = (try? c.decodeIfPresent(String.self, forKey: .resetsAt)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(percentUsed, forKey: .percentUsed)
        try c.encode(resetsAt, forKey: .resetsAt)
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

extension ClineUsageResponse {
    /// Convenience accessors that resolve the flat `limits` array into the three
    /// known buckets. The API may return them in any order, so we look up by `type`.
    var fiveHour: ClineLimit? { data.limits.first { $0.type == "five_hour" } }
    var weekly: ClineLimit? { data.limits.first { $0.type == "weekly" } }
    var monthly: ClineLimit? { data.limits.first { $0.type == "monthly" } }
}

// MARK: - App State

class SettingsState: ObservableObject {
    static let notchOverlayKey = "notchOverlayEnabled"

    @Published var orgId: String = ""
    @Published var cookie: String = ""
    @Published var openRouterKey: String = ""
    @Published var clineSessionCookie: String = ""
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

    @Published var clineUsage: ClineUsageResponse?
    @Published var clineError: String?

    // Cline Pass burn-rate trackers — one per rolling window. Window size matches
    // the bucket's reset cadence so the sample history never straddles a reset.
    let clineFiveHourBurnRate = BurnRateTracker(maxSampleAge: 5 * 3600)
    let clineWeeklyBurnRate   = BurnRateTracker(maxSampleAge: 7 * 24 * 3600)
    let clineMonthlyBurnRate  = BurnRateTracker(maxSampleAge: 30 * 24 * 3600)

    // One tracker per Anthropic bucket. Window size matches the bucket's reset
    // cadence so the sample history never straddles a reset boundary.
    let sessionBurnRate = BurnRateTracker(maxSampleAge: 5 * 3600)
    let weeklyBurnRate  = BurnRateTracker(maxSampleAge: 7 * 24 * 3600)
    let sonnetBurnRate  = BurnRateTracker(maxSampleAge: 7 * 24 * 3600)
    let designBurnRate  = BurnRateTracker(maxSampleAge: 7 * 24 * 3600)

    var sessionUtilization: Int {
        usage?.fiveHour?.utilization ?? 0
    }

    var sessionResetTime: String {
        usage?.fiveHour?.timeUntilReset ?? "N/A"
    }

    /// Projected utilization (%) at the bucket's reset. Same unit as Anthropic's
    /// `utilization` field. Returns nil when not enough samples or not consuming.
    var sessionProjectedUtilization: Int? {
        guard let resetDate = usage?.fiveHour?.resetDate else { return nil }
        return sessionBurnRate.projectedUtilization(at: resetDate)
    }

    var weeklyUtilization: Int {
        usage?.sevenDay?.utilization ?? 0
    }

    var weeklyResetTime: String {
        usage?.sevenDay?.timeUntilReset ?? "N/A"
    }

    var weeklyProjectedUtilization: Int? {
        guard let resetDate = usage?.sevenDay?.resetDate else { return nil }
        return weeklyBurnRate.projectedUtilization(at: resetDate)
    }

    var sonnetUtilization: Int {
        usage?.sevenDaySonnet?.utilization ?? 0
    }

    var sonnetProjectedUtilization: Int? {
        guard let resetDate = usage?.sevenDaySonnet?.resetDate else { return nil }
        return sonnetBurnRate.projectedUtilization(at: resetDate)
    }

    var designUtilization: Int {
        usage?.sevenDayOmelette?.utilization ?? 0
    }

    var designProjectedUtilization: Int? {
        guard let resetDate = usage?.sevenDayOmelette?.resetDate else { return nil }
        return designBurnRate.projectedUtilization(at: resetDate)
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

    // MARK: - Cline Pass

    var clineFiveHourUtilization: Int {
        clineUsage?.fiveHour?.percentUsed ?? 0
    }

    var clineFiveHourResetTime: String {
        clineUsage?.fiveHour?.timeUntilReset ?? "N/A"
    }

    var clineFiveHourProjectedUtilization: Int? {
        guard let resetDate = clineUsage?.fiveHour?.resetDate else { return nil }
        return clineFiveHourBurnRate.projectedUtilization(at: resetDate)
    }

    var clineWeeklyUtilization: Int {
        clineUsage?.weekly?.percentUsed ?? 0
    }

    var clineWeeklyResetTime: String {
        clineUsage?.weekly?.timeUntilReset ?? "N/A"
    }

    var clineWeeklyProjectedUtilization: Int? {
        guard let resetDate = clineUsage?.weekly?.resetDate else { return nil }
        return clineWeeklyBurnRate.projectedUtilization(at: resetDate)
    }

    var clineMonthlyUtilization: Int {
        clineUsage?.monthly?.percentUsed ?? 0
    }

    var clineMonthlyResetTime: String {
        clineUsage?.monthly?.timeUntilReset ?? "N/A"
    }

    var clineMonthlyProjectedUtilization: Int? {
        guard let resetDate = clineUsage?.monthly?.resetDate else { return nil }
        return clineMonthlyBurnRate.projectedUtilization(at: resetDate)
    }
}
