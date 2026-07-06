import Foundation
import UserNotifications

/// Centralized macOS notification logic for the app.
///
/// Only two notification types are ever fired (by design — avoid notification fatigue):
///
/// 1. **Critical threshold (90%)** — fired when a 5-hour session (Claude or Cline)
///    crosses 90% utilization. Each bucket is notified at most once per crossing;
///    it re-arms when utilization drops back below 80% (i.e. a reset occurred).
/// 2. **Cookie expired** — fired when any API returns 401/403. Once per "session"
///    of being expired; re-arms when a refresh succeeds.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    // MARK: - Configuration

    private let criticalThreshold = 90
    private let clearThreshold = 80

    // MARK: - Dedup state

    /// Per-bucket flag: true once we've fired the critical notification, cleared
    /// when utilization drops back below `clearThreshold` (reset detection).
    private var criticalNotified: [String: Bool] = [:]
    /// Prevents repeated cookie-expired notifications during the same outage.
    private var cookieExpiredNotified = false

    // MARK: - Public API

    /// Requests notification authorization. Called once at app launch. macOS shows
    /// the system permission prompt on first call; subsequent calls are no-ops if
    /// the user already granted/denied.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Evaluates 5-hour session utilization for Claude and Cline. Fires a critical
    /// notification when a bucket crosses 90%, with dedup per bucket.
    func checkCriticalThreshold(claude5h: Int, cline5h: Int) {
        evaluate(bucket: "claude_5h", utilization: claude5h, label: "Claude — Session (5h)")
        evaluate(bucket: "cline_5h", utilization: cline5h, label: "Cline Pass — Session (5h)")
    }

    /// Fires a cookie-expired notification (once per outage). Re-armed by
    /// `clearCookieExpired()`, which should be called when a refresh succeeds.
    func notifyCookieExpired(service: String) {
        guard !cookieExpiredNotified else { return }
        cookieExpiredNotified = true

        let content = UNMutableNotificationContent()
        content.title = "🔐 Session expirée"
        content.body = "\(service) — re-configurer dans les réglages"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "cookie_expired_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Re-arms the cookie-expired notification so a future 401 can notify again.
    func clearCookieExpired() {
        cookieExpiredNotified = false
    }

    // MARK: - Internal

    private func evaluate(bucket: String, utilization: Int, label: String) {
        let alreadyNotified = criticalNotified[bucket] ?? false
        if utilization >= criticalThreshold && !alreadyNotified {
            sendCritical(bucket: bucket, utilization: utilization, label: label)
            criticalNotified[bucket] = true
        } else if utilization < clearThreshold && alreadyNotified {
            // Bucket reset (or dropped well below threshold) — re-arm for next time.
            criticalNotified[bucket] = false
        }
    }

    private func sendCritical(bucket: String, utilization: Int, label: String) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ Limite bientôt atteinte"
        content.body = "\(label) : \(utilization)% utilisé"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "critical_\(bucket)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}