import Foundation
import UserNotifications

/// Centralized macOS notification logic for the app.
///
/// Three notification families are supported, all deduplicated to avoid fatigue:
///
/// 1. **Critical threshold (90%)** — fired when a 5-hour session (Claude or Cline)
///    crosses 90% utilization. Each bucket is notified at most once per crossing;
///    it re-arms when utilization drops back below 80% (i.e. a reset occurred).
/// 2. **Cookie expired** — fired when any API returns 401/403. Once per "session"
///    of being expired; re-arms when a refresh succeeds.
/// 3. **Anomaly opened** — fired once per persisted incident ID. Resolutions stay
///    in the in-app journal and do not produce another notification.
///
/// **Bundle requirement:** `UNUserNotificationCenter` crashes with an internal
/// `NSAssertionHandler` failure (which surfaces as `EXC_BAD_ACCESS / SIGSEGV`) when
/// the app has no `CFBundleIdentifier` — i.e. when the raw SwiftPM executable is
/// launched directly instead of from a `.app` bundle. To stay crash-free in both
/// contexts, every method checks `notificationsEnabled` (which verifies a valid
/// bundle identifier exists) and silently no-ops when the app runs outside a bundle.
final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    // MARK: - Configuration

    private let criticalThreshold = 90
    private let clearThreshold = 80

    /// Returns `true` only when the app is running inside a proper `.app` bundle
    /// (i.e. `Bundle.main.bundleIdentifier` is set). `UNUserNotificationCenter`
    /// asserts/crashes without a bundle identifier, so we gate every call on this.
    private var notificationsEnabled: Bool {
        Bundle.main.bundleIdentifier != nil
            && UserDefaults.standard.bool(forKey: SettingsState.alertsKey)
    }

    // MARK: - Dedup state

    /// Per-bucket flag: true once we've fired the critical notification, cleared
    /// when utilization drops back below `clearThreshold` (reset detection).
    private var criticalNotified: [String: Bool] = [:]
    /// Prevents repeated cookie-expired notifications during the same outage.
    private var cookieExpiredNotified = false

    // MARK: - Public API

    /// Requests notification authorization. Called once at app launch (deferred).
    /// macOS shows the system permission prompt on first call; subsequent calls
    /// are no-ops if the user already granted/denied. Silently skipped when the
    /// app is not running inside a `.app` bundle (raw executable has no bundle id).
    func requestPermission() {
        guard notificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Evaluates 5-hour session utilization for Claude and Cline. Fires a critical
    /// notification when a bucket crosses 90%, with dedup per bucket. No-ops when
    /// the app is not running inside a `.app` bundle.
    func checkCriticalThreshold(claude5h: Int, cline5h: Int) {
        guard notificationsEnabled else { return }
        evaluate(bucket: "claude_5h", utilization: claude5h, label: "Claude — Session (5h)")
        evaluate(bucket: "cline_5h", utilization: cline5h, label: "Cline Pass — Session (5h)")
    }

    /// Fires a cookie-expired notification (once per outage). Re-armed by
    /// `clearCookieExpired()`, which should be called when a refresh succeeds.
    /// No-ops when the app is not running inside a `.app` bundle.
    func notifyCookieExpired(service: String) {
        guard notificationsEnabled else { return }
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

    /// Sends one notification per anomaly occurrence. IDs are persisted so an app
    /// restart or a server re-sync cannot replay the same incident.
    func notifyAnomaly(_ event: AnomalyEvent) {
        guard notificationsEnabled, event.isOpen else { return }
        let defaultsKey = "notifiedAnomalyIDs"
        var notified = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        guard !notified.contains(event.id) else { return }
        notified.append(event.id)
        if notified.count > 200 { notified.removeFirst(notified.count - 200) }
        UserDefaults.standard.set(notified, forKey: defaultsKey)

        let content = UNMutableNotificationContent()
        content.title = event.isCritical ? "🚨 Anomalie critique" : "⚠️ Anomalie détectée"
        content.body = event.message
        content.sound = event.isCritical ? .defaultCritical : .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "anomaly_\(event.id)", content: content, trigger: nil
        ))
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
