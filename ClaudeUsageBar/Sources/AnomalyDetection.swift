import Foundation

enum AnomalyProfile: String, Codable, CaseIterable, Identifiable {
    case calm, balanced, sensitive

    var id: String { rawValue }
    var label: String {
        switch self {
        case .calm: return "Calme"
        case .balanced: return "Équilibré"
        case .sensitive: return "Sensible"
        }
    }
    var robustScore: Double {
        switch self { case .calm: return 5; case .balanced: return 4; case .sensitive: return 3 }
    }
    var modelConfirmations: Int {
        switch self { case .calm: return 3; case .balanced: return 2; case .sensitive: return 1 }
    }
}

struct AnomalyBaseline: Codable, Equatable {
    let median: Double
    let mad: Double
    let low: Double
    let high: Double
}

struct AnomalyEvent: Codable, Identifiable, Equatable {
    let id: String
    let source: String
    let metric: String
    var severity: String
    var state: String
    let startedAt: Date
    var resolvedAt: Date?
    var observedValue: Double?
    var baseline: AnomalyBaseline?
    var message: String

    var isOpen: Bool { state == "open" }
    var isCritical: Bool { severity == "critical" }
}

struct VPSAnomalySummary: Codable {
    let openCount: Int
    let maxSeverity: String?
    let latest: ServerAnomalyEvent?

    enum CodingKeys: String, CodingKey {
        case openCount = "open_count"
        case maxSeverity = "max_severity"
        case latest
    }
}

struct ServerAnomalyEvent: Codable {
    let id: String
    let source: String
    let metric: String
    let severity: String
    let state: String
    let startedAt: String
    let resolvedAt: String?
    let observedValue: Double?
    let baseline: AnomalyBaseline?
    let message: String

    enum CodingKeys: String, CodingKey {
        case id, source, metric, severity, state, baseline, message
        case startedAt = "started_at"
        case resolvedAt = "resolved_at"
        case observedValue = "observed_value"
    }

    func localEvent() -> AnomalyEvent? {
        guard let started = Self.parse(startedAt) else { return nil }
        return AnomalyEvent(
            id: id, source: source, metric: metric, severity: severity, state: state,
            startedAt: started, resolvedAt: resolvedAt.flatMap(Self.parse),
            observedValue: observedValue, baseline: baseline, message: message
        )
    }

    private static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

struct VPSAnomaliesResponse: Codable {
    let events: [ServerAnomalyEvent]
    let settings: VPSAnomalySettings
}

struct VPSAnomalySettings: Codable {
    let profile: AnomalyProfile
    let vpsEnabled: Bool
    let modelEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case profile
        case vpsEnabled = "vps_enabled"
        case modelEnabled = "model_enabled"
    }
}

fileprivate struct LocalMetricSample: Codable {
    let key: String
    let timestamp: Date
    let value: Double
}

fileprivate struct LocalCandidate: Codable {
    var badCount = 0
    var goodCount = 0
}

fileprivate struct LocalAnomalyState: Codable {
    var samples: [LocalMetricSample] = []
    var candidates: [String: LocalCandidate] = [:]
}

enum AnomalyHistoryStore {
    private static let retention: TimeInterval = 7 * 24 * 3600
    private static let queue = DispatchQueue(label: "com.louismasson.ClaudeUsageBar.anomalies", qos: .utility)

    static func loadEvents() -> [AnomalyEvent] {
        guard let data = try? Data(contentsOf: eventsURL),
              let events = try? JSONDecoder().decode([AnomalyEvent].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-retention)
        return events.filter { $0.isOpen || ($0.resolvedAt ?? $0.startedAt) >= cutoff }
    }

    static func saveEvents(_ events: [AnomalyEvent]) {
        save(events, to: eventsURL)
    }

    fileprivate static func loadState() -> LocalAnomalyState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(LocalAnomalyState.self, from: data) else { return LocalAnomalyState() }
        return state
    }

    fileprivate static func saveState(_ state: LocalAnomalyState) {
        save(state, to: stateURL)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClaudeUsageBar", isDirectory: true)
    }
    private static var eventsURL: URL { directory.appendingPathComponent("anomaly-events.json") }
    private static var stateURL: URL { directory.appendingPathComponent("anomaly-model-state.json") }
}

@MainActor
final class LocalAnomalyDetector {
    private var state: LocalAnomalyState
    private let persistChanges: Bool
    private let retention: TimeInterval = 7 * 24 * 3600

    init(persistChanges: Bool = true) {
        self.persistChanges = persistChanges
        self.state = persistChanges ? AnomalyHistoryStore.loadState() : LocalAnomalyState()
    }

    static func robustBaseline(_ values: [Double]) -> AnomalyBaseline? {
        guard values.count >= 12 else { return nil }
        let sorted = values.sorted()
        let median = medianOfSorted(sorted)
        let deviations = values.map { abs($0 - median) }.sorted()
        let mad = medianOfSorted(deviations)
        return AnomalyBaseline(
            median: median, mad: mad,
            low: max(0, median - 2.9652 * mad),
            high: median + 2.9652 * mad
        )
    }

    private static func medianOfSorted(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }

    func recordQuota(
        source: String, metric: String, utilization: Int, projected: Int?,
        profile: AnomalyProfile, events: inout [AnomalyEvent], at date: Date = Date()
    ) -> [AnomalyEvent] {
        let sampleKey = "\(source):\(metric)"
        let previous = state.samples.last { $0.key == sampleKey }
        if let previous, Double(utilization) < previous.value {
            // Expected quota reset: discard the old slope and never report the drop.
            state.samples.removeAll { $0.key == sampleKey }
            state.candidates.keys.filter { $0.hasPrefix(sampleKey) }.forEach { state.candidates.removeValue(forKey: $0) }
        }

        let slopes = historicalSlopes(for: sampleKey)
        var newEvents: [AnomalyEvent] = []
        if let previous, date.timeIntervalSince(previous.timestamp) >= 60, utilization >= Int(previous.value) {
            let hours = date.timeIntervalSince(previous.timestamp) / 3600
            let currentSlope = (Double(utilization) - previous.value) / hours
            if let baseline = Self.robustBaseline(slopes) {
                let spread = max(0.5, 1.4826 * baseline.mad)
                let abnormal = currentSlope >= max(2, baseline.median + profile.robustScore * spread)
                transition(
                    key: "\(sampleKey):burn_rate", source: source, metric: "\(metric)_burn_rate",
                    severity: abnormal ? "warning" : nil, observed: currentSlope, baseline: baseline,
                    message: abnormal ? "Consommation \(source) inhabituellement rapide (\(Int(currentSlope.rounded())) points/h)" : "",
                    confirmations: profile.modelConfirmations, events: &events, opened: &newEvents, at: date
                )
            }
        }
        state.samples.append(LocalMetricSample(key: sampleKey, timestamp: date, value: Double(utilization)))

        transition(
            key: "\(sampleKey):limit", source: source, metric: metric,
            severity: utilization >= 90 ? "critical" : nil, observed: Double(utilization), baseline: nil,
            message: utilization >= 90 ? "\(source) atteint \(utilization)% de sa limite" : "",
            confirmations: 1, events: &events, opened: &newEvents, at: date
        )
        transition(
            key: "\(sampleKey):projection", source: source, metric: "\(metric)_projection",
            severity: (projected ?? 0) > 100 ? "warning" : nil, observed: projected.map(Double.init), baseline: nil,
            message: (projected ?? 0) > 100 ? "\(source) est projeté à \(projected!)% au reset" : "",
            confirmations: profile.modelConfirmations, events: &events, opened: &newEvents, at: date
        )
        persist(at: date, events: &events)
        return newEvents
    }

    func recordDailyPace(
        source: String, metric: String, todayValue: Double, previousDays: [Double], attribution: String?,
        profile: AnomalyProfile, isCompleteDay: Bool = false,
        events: inout [AnomalyEvent], at date: Date = Date()
    ) -> [AnomalyEvent] {
        guard previousDays.count >= 3 else { return [] }
        let calendar = Calendar.current
        let seconds = max(3600, date.timeIntervalSince(calendar.startOfDay(for: date)))
        let projected = isCompleteDay ? todayValue : todayValue / (seconds / 86400)
        let baseline = Self.robustBaseline(Array(repeating: previousDays, count: 4).flatMap { $0 })
        guard let baseline else { return [] }
        let spread = max(baseline.median * 0.1, 1.4826 * baseline.mad)
        let minimumAbsolute = metric == "daily_spend" ? 0.5 : 10_000
        let abnormal = projected >= minimumAbsolute
            && projected >= max(baseline.median * 2, baseline.median + profile.robustScore * spread)
        var opened: [AnomalyEvent] = []
        let suffix = attribution.map { " · principal: \($0)" } ?? ""
        transition(
            key: "\(source):\(metric):daily", source: source, metric: metric,
            severity: abnormal ? "warning" : nil, observed: projected, baseline: baseline,
            message: abnormal ? "Rythme journalier \(source) inhabituel\(suffix)" : "",
            confirmations: profile.modelConfirmations, events: &events, opened: &opened, at: date
        )
        persist(at: date, events: &events)
        return opened
    }

    private func historicalSlopes(for key: String) -> [Double] {
        let samples = state.samples.filter { $0.key == key }.sorted { $0.timestamp < $1.timestamp }
        guard samples.count > 1 else { return [] }
        return zip(samples, samples.dropFirst()).compactMap { first, second in
            let hours = second.timestamp.timeIntervalSince(first.timestamp) / 3600
            guard hours >= 1.0 / 60, second.value >= first.value else { return nil }
            return (second.value - first.value) / hours
        }
    }

    private func transition(
        key: String, source: String, metric: String, severity: String?, observed: Double?,
        baseline: AnomalyBaseline?, message: String, confirmations: Int,
        events: inout [AnomalyEvent], opened: inout [AnomalyEvent], at date: Date
    ) {
        var candidate = state.candidates[key] ?? LocalCandidate()
        let openIndex = events.firstIndex { $0.id.hasPrefix(key + "#") && $0.isOpen }
        if let severity {
            candidate.badCount += 1
            candidate.goodCount = 0
            if let openIndex {
                events[openIndex].severity = severity
                events[openIndex].observedValue = observed
                events[openIndex].baseline = baseline
                events[openIndex].message = message
            } else if candidate.badCount >= confirmations {
                let event = AnomalyEvent(
                    id: "\(key)#\(Int(date.timeIntervalSince1970))", source: source, metric: metric, severity: severity, state: "open",
                    startedAt: date, resolvedAt: nil, observedValue: observed, baseline: baseline, message: message
                )
                events.append(event)
                opened.append(event)
            }
        } else {
            candidate.badCount = 0
            candidate.goodCount += 1
            if let openIndex, candidate.goodCount >= 2 {
                events[openIndex].state = "resolved"
                events[openIndex].resolvedAt = date
            }
        }
        state.candidates[key] = candidate
    }

    private func persist(at date: Date, events: inout [AnomalyEvent]) {
        let cutoff = date.addingTimeInterval(-retention)
        state.samples.removeAll { $0.timestamp < cutoff }
        events.removeAll { !$0.isOpen && ($0.resolvedAt ?? $0.startedAt) < cutoff }
        if persistChanges {
            AnomalyHistoryStore.saveState(state)
            AnomalyHistoryStore.saveEvents(events)
        }
    }
}
