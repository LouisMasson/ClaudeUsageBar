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

struct OpenRouterActivityResponse: Decodable {
    let data: [OpenRouterActivityItem]
}

struct OpenRouterActivityItem: Decodable, Identifiable {
    let byokUsageInference: Double
    let completionTokens: Int
    let date: String
    let endpointID: String?
    let model: String
    let modelPermaslug: String?
    let promptTokens: Int
    let providerName: String
    let reasoningTokens: Int
    let requests: Int
    let usage: Double

    var id: String { "\(date)|\(endpointID ?? "")|\(model)|\(providerName)" }
    var tokenVolume: Int { promptTokens + completionTokens }

    enum CodingKeys: String, CodingKey {
        case byokUsageInference = "byok_usage_inference"
        case completionTokens = "completion_tokens"
        case date
        case endpointID = "endpoint_id"
        case model
        case modelPermaslug = "model_permaslug"
        case promptTokens = "prompt_tokens"
        case providerName = "provider_name"
        case reasoningTokens = "reasoning_tokens"
        case requests
        case usage
    }
}

struct OpenRouterAPIKeysResponse: Decodable {
    let data: [OpenRouterAPIKey]
}

struct OpenRouterAPIKey: Decodable {
    let hash: String
    let name: String?
    let label: String?
    let disabled: Bool?

    var displayName: String {
        let candidate = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate, !candidate.isEmpty { return candidate }
        if let label, !label.isEmpty { return label }
        return "Clé \(hash.prefix(7))"
    }
}

struct OpenRouterKeyActivity: Identifiable {
    let keyHash: String
    let name: String
    let items: [OpenRouterActivityItem]

    var id: String { keyHash }
}

struct OpenRouterDimensionActivity: Identifiable {
    let date: String
    let name: String
    let spend: Double
    let requests: Int
    let tokens: Int

    var id: String { "\(date)|\(name)" }
}

struct OpenRouterActivitySnapshot {
    let items: [OpenRouterActivityItem]
    let cacheHitRates: [String: Double]
    let modelActivities: [OpenRouterDimensionActivity]
    let appActivities: [OpenRouterDimensionActivity]
    let keyActivities: [OpenRouterDimensionActivity]
    let fetchedAt: Date

    func summary(days: Int) -> OpenRouterActivitySummary {
        OpenRouterActivitySummary(
            items: items,
            cacheHitRates: cacheHitRates,
            modelActivities: modelActivities,
            appActivities: appActivities,
            keyActivities: keyActivities,
            days: days
        )
    }
}

struct OpenRouterActivityRank: Identifiable {
    let name: String
    let spend: Double
    let requests: Int
    let tokens: Int

    var id: String { name }
}

struct OpenRouterDailyActivity: Identifiable {
    let date: String
    let spend: Double
    let requests: Int
    let tokens: Int

    var id: String { date }
}

struct OpenRouterActivitySummary {
    let days: Int
    let spend: Double
    let requests: Int
    let tokens: Int
    let reasoningTokens: Int
    let byokInference: Double
    let blendedCostPerMillion: Double
    let cacheHitRate: Double?
    let spendChange: Double?
    let requestsChange: Double?
    let tokensChange: Double?
    let daily: [OpenRouterDailyActivity]
    let topModels: [OpenRouterActivityRank]
    let topProviders: [OpenRouterActivityRank]
    let topApps: [OpenRouterActivityRank]
    let topKeys: [OpenRouterActivityRank]

    init(
        items: [OpenRouterActivityItem],
        cacheHitRates: [String: Double] = [:],
        modelActivities: [OpenRouterDimensionActivity] = [],
        appActivities: [OpenRouterDimensionActivity] = [],
        keyActivities: [OpenRouterDimensionActivity] = [],
        days: Int
    ) {
        self.days = days
        let dates = Array(Set(items.map(\.date))).sorted()
        let latestDate = dates.last.flatMap(Self.activityDateFormatter.date)
        let currentDateStrings = Self.periodDates(endingAt: latestDate, days: days)
        let previousEnd = latestDate.flatMap { Self.utcCalendar.date(byAdding: .day, value: -days, to: $0) }
        let previousDateStrings = Self.periodDates(endingAt: previousEnd, days: days)
        let selectedDates = Set(currentDateStrings)
        let previousDates = Set(previousDateStrings)
        let current = items.filter { selectedDates.contains($0.date) }
        let previous = items.filter { previousDates.contains($0.date) }

        spend = current.reduce(0) { $0 + $1.usage }
        requests = current.reduce(0) { $0 + $1.requests }
        tokens = current.reduce(0) { $0 + $1.tokenVolume }
        reasoningTokens = current.reduce(0) { $0 + $1.reasoningTokens }
        byokInference = current.reduce(0) { $0 + $1.byokUsageInference }
        blendedCostPerMillion = tokens > 0 ? spend / Double(tokens) * 1_000_000 : 0
        let cacheWeightedRows = current.compactMap { item -> (Double, Int)? in
            guard let rate = cacheHitRates[item.date] else { return nil }
            return (rate, item.tokenVolume)
        }
        let cacheWeight = cacheWeightedRows.reduce(0) { $0 + $1.1 }
        cacheHitRate = cacheWeight > 0
            ? cacheWeightedRows.reduce(0) { $0 + $1.0 * Double($1.1) } / Double(cacheWeight)
            : nil

        let previousSpend = previous.reduce(0) { $0 + $1.usage }
        let previousRequests = previous.reduce(0) { $0 + $1.requests }
        let previousTokens = previous.reduce(0) { $0 + $1.tokenVolume }
        spendChange = Self.change(current: spend, previous: previousSpend)
        requestsChange = Self.change(current: Double(requests), previous: Double(previousRequests))
        tokensChange = Self.change(current: Double(tokens), previous: Double(previousTokens))

        daily = currentDateStrings.map { date in
            let rows = current.filter { $0.date == date }
            return OpenRouterDailyActivity(
                date: date,
                spend: rows.reduce(0) { $0 + $1.usage },
                requests: rows.reduce(0) { $0 + $1.requests },
                tokens: rows.reduce(0) { $0 + $1.tokenVolume }
            )
        }
        topModels = modelActivities.isEmpty
            ? Self.rank(current, name: { $0.model })
            : Self.rankDimensions(modelActivities.filter { selectedDates.contains($0.date) })
        topProviders = Self.rank(current, name: { $0.providerName })
        topApps = Self.rankDimensions(appActivities.filter { selectedDates.contains($0.date) })
        topKeys = Self.rankDimensions(keyActivities.filter { selectedDates.contains($0.date) })
    }

    private static func rank(
        _ items: [OpenRouterActivityItem],
        name: (OpenRouterActivityItem) -> String
    ) -> [OpenRouterActivityRank] {
        Dictionary(grouping: items, by: name).map { label, rows in
            OpenRouterActivityRank(
                name: label,
                spend: rows.reduce(0) { $0 + $1.usage },
                requests: rows.reduce(0) { $0 + $1.requests },
                tokens: rows.reduce(0) { $0 + $1.tokenVolume }
            )
        }
        .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .sorted { $0.tokens == $1.tokens ? $0.spend > $1.spend : $0.tokens > $1.tokens }
    }

    private static func rankDimensions(_ items: [OpenRouterDimensionActivity]) -> [OpenRouterActivityRank] {
        Dictionary(grouping: items, by: \.name).map { label, rows in
            OpenRouterActivityRank(
                name: label,
                spend: rows.reduce(0) { $0 + $1.spend },
                requests: rows.reduce(0) { $0 + $1.requests },
                tokens: rows.reduce(0) { $0 + $1.tokens }
            )
        }
        .filter { $0.requests > 0 || $0.spend > 0 || $0.tokens > 0 }
        .sorted { $0.tokens == $1.tokens ? $0.spend > $1.spend : $0.tokens > $1.tokens }
    }

    private static func change(current: Double, previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous * 100
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static var activityDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = utcCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func periodDates(endingAt endDate: Date?, days: Int) -> [String] {
        guard let endDate else { return [] }
        return (0..<days).compactMap { offset in
            utcCalendar.date(byAdding: .day, value: offset - days + 1, to: endDate)
        }.map(activityDateFormatter.string)
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

// MARK: - Shared UI palette

import SwiftUI
import AppKit

/// Shared color palette for all utilization indicators across the app.
///
/// `.green` / `.systemGreen` are too bright/flashy against the popover and notch
/// backgrounds, so we use a darker, less saturated shade that reads as "healthy"
/// without being jarring. Orange and red stay close to the system tints but are
/// slightly muted for visual consistency with the green.
enum UsagePalette {
    /// Muted green — "everything is fine" (< 60%).
    static let green = Color(red: 0.18, green: 0.52, blue: 0.33)
    /// Muted orange — "getting close" (60–85%).
    static let orange = Color(red: 0.78, green: 0.45, blue: 0.13)
    /// Muted red — "will hit the limit" (≥ 85%).
    static let red = Color(red: 0.72, green: 0.20, blue: 0.18)

    /// AppKit equivalents (for the menu bar `NSStatusItem`, which uses `NSColor`).
    static let greenNS = NSColor(srgbRed: 0.18, green: 0.52, blue: 0.33, alpha: 1)
    static let orangeNS = NSColor(srgbRed: 0.78, green: 0.45, blue: 0.13, alpha: 1)
    static let redNS = NSColor(srgbRed: 0.72, green: 0.20, blue: 0.18, alpha: 1)

    /// SwiftUI color for a given utilization reference (projection or current).
    static func color(for reference: Int) -> Color {
        switch reference {
        case ..<60:  return green
        case ..<85:  return orange
        default:     return red
        }
    }

    /// AppKit color for a given utilization reference (projection or current).
    static func nsColor(for reference: Int) -> NSColor {
        switch reference {
        case ..<60:  return greenNS
        case ..<85:  return orangeNS
        default:     return redNS
        }
    }
}

// MARK: - App State

class SettingsState: ObservableObject {
    static let notchOverlayKey = "notchOverlayEnabled"
    static let claudeOAuthKey = "claudeOAuthEnabled"
    static let alertsKey = "alertsEnabled"

    @Published var orgId: String = ""
    @Published var cookie: String = ""
    @Published var openRouterKey: String = ""
    @Published var openRouterManagementKey: String = ""
    @Published var clineSessionCookie: String = ""
    @Published var vpsBaseURL: String = "https://status.patronusguardian.org"
    @Published var vpsAPIToken: String = ""
    @Published var claudeOAuthEnabled: Bool = UserDefaults.standard.object(forKey: SettingsState.claudeOAuthKey) == nil
        ? true
        : UserDefaults.standard.bool(forKey: SettingsState.claudeOAuthKey)
    @Published var alertsEnabled: Bool = UserDefaults.standard.bool(forKey: SettingsState.alertsKey)
    @Published var launchAtLoginEnabled: Bool = LaunchAtLoginManager.isEnabled
    @Published var notchOverlayEnabled: Bool = UserDefaults.standard.bool(forKey: SettingsState.notchOverlayKey)
    @Published var menuBarIcon: MenuBarIcon = .saved
}

@MainActor
class UsageState: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastUpdated: Date?

    @Published var openRouterCredits: OpenRouterCredits?
    @Published var openRouterError: String?
    @Published var openRouterActivity: OpenRouterActivitySnapshot?
    @Published var openRouterActivityError: String?
    @Published var isLoadingOpenRouterActivity = false

    @Published var clineUsage: ClineUsageResponse?
    @Published var clineError: String?

    @Published var vpsStatus: VPSMenuStatus?
    @Published var vpsError: String?
    @Published var vpsLastUpdated: Date?
    @Published var vpsHistory: [VPSHistorySample] = VPSHistoryStore.load()

    /// True when Claude's API returned 401/403 — the popover swaps to a
    /// "session expired" view with a shortcut to Settings.
    @Published var cookieExpired = false

    /// True when a refresh failed due to a transient error (network/5xx) **but**
    /// we still have cached data to display. The popover shows a discrete
    /// "Hors ligne" badge instead of replacing the data with an error banner.
    @Published var isOffline = false

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

    func recordVPS(_ status: VPSMenuStatus, at date: Date = Date()) {
        let sample = VPSHistorySample(
            timestamp: date,
            cpu: status.vps.cpuPercent,
            ram: status.vps.ramPercent,
            disk: status.vps.diskPercent
        )
        vpsHistory = VPSHistoryStore.append(sample, to: vpsHistory)
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
