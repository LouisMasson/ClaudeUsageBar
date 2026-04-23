import Foundation

/// Tracks utilization samples over time for a single bucket (e.g. the 5h rolling window)
/// and projects where utilization will land at a given future moment using a linear slope.
///
/// Typology-preserving: inputs and outputs are utilization percentages (0-100), identical
/// to Anthropic's API. The projection is an *additional* % figure, never a replacement.
@MainActor
final class BurnRateTracker {
    private struct Sample {
        let timestamp: Date
        let utilization: Int
    }

    private var samples: [Sample] = []
    private let maxSamples: Int
    private let minSamplesForProjection = 2
    private let minWindowSeconds: TimeInterval = 5 * 60
    /// Samples older than this are evicted on every record. Should match the bucket's
    /// reset cadence so history never straddles a reset boundary (e.g. 5h for the
    /// session window, 7 days for weekly buckets).
    private let maxSampleAge: TimeInterval

    init(maxSampleAge: TimeInterval = 5 * 3600, maxSamples: Int = 12) {
        self.maxSampleAge = maxSampleAge
        self.maxSamples = maxSamples
    }

    /// Record a new utilization reading. Handles two sources of history drift:
    /// 1. Explicit reset detection: utilization dropped vs the previous sample → flush.
    /// 2. Temporal purge: drop samples older than `maxSampleAge` so the slope never
    ///    spans a missed reset (e.g. Mac slept through it).
    func record(utilization: Int, at date: Date = Date()) {
        if let last = samples.last, utilization < last.utilization {
            samples.removeAll()
        }
        samples.removeAll { date.timeIntervalSince($0.timestamp) > maxSampleAge }
        samples.append(Sample(timestamp: date, utilization: utilization))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// Reset history (e.g. when switching accounts or on explicit user refresh failure).
    func reset() { samples.removeAll() }

    /// Project utilization (%) at `target`. Returns nil when:
    /// - fewer than 2 samples exist
    /// - the sampling window is too short to produce a stable slope
    /// - slope is zero or negative (not consuming, projection would be noise)
    /// - the target is in the past
    func projectedUtilization(at target: Date) -> Int? {
        guard samples.count >= minSamplesForProjection else { return nil }
        guard let first = samples.first, let last = samples.last else { return nil }
        let window = last.timestamp.timeIntervalSince(first.timestamp)
        guard window >= minWindowSeconds else { return nil }

        let delta = Double(last.utilization - first.utilization)
        guard delta > 0 else { return nil }  // not consuming, no useful forecast

        let slopePerSecond = delta / window
        let secondsAhead = target.timeIntervalSince(last.timestamp)
        guard secondsAhead > 0 else { return nil }

        let projected = Double(last.utilization) + slopePerSecond * secondsAhead
        return max(0, min(999, Int(projected.rounded())))
    }
}
