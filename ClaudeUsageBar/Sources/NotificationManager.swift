import Foundation
import UserNotifications

/// Centralized macOS notification logic for the app.
///
/// Six notification families are supported, all deduplicated to avoid fatigue:
///
/// 1. **Critical threshold (90%)** — fired when a 5-hour session (Claude or Cline)
///    crosses 90% utilization. Each bucket is notified at most once per crossing;
///    it re-arms when utilization drops back below 80% (i.e. a reset occurred).
/// 2. **Cookie expired** — fired when any API returns 401/403. Once per "session"
///    of being expired; re-arms when a refresh succeeds.
/// 3. **Anomaly opened** — fired once per persisted incident ID. Resolutions stay
///    in the in-app journal and do not produce another notification.
/// 4. **Dokploy deployment finished** — fired once after a deployment reaches
///    `done`, `error` or `cancelled`.
/// 5. **OpenRouter low balance** — fired once when remaining credit drops below
///    $2, and re-armed after the balance returns to at least $2.
/// 6. **Pomodoro completed** — scheduled when a focus session starts and cancelled
///    when it is paused or reset.
///
/// **Bundle requirement:** `UNUserNotificationCenter` crashes with an internal
/// `NSAssertionHandler` failure (which surfaces as `EXC_BAD_ACCESS / SIGSEGV`) when
/// the app has no `CFBundleIdentifier` — i.e. when the raw SwiftPM executable is
/// launched directly instead of from a `.app` bundle. To stay crash-free in both
/// contexts, every method verifies a valid bundle identifier and silently no-ops
/// when the app runs outside a bundle.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private override init() {
        super.init()
    }

    // MARK: - Configuration

    private let criticalThreshold = 90
    private let clearThreshold = 80

    /// Returns `true` only when the app is running inside a proper `.app` bundle
    /// (i.e. `Bundle.main.bundleIdentifier` is set). `UNUserNotificationCenter`
    /// asserts/crashes without a bundle identifier, so we gate every call on this.
    private var notificationsEnabled: Bool {
        hasValidBundleIdentifier
            && UserDefaults.standard.bool(forKey: SettingsState.alertsKey)
    }

    private var hasValidBundleIdentifier: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    // MARK: - Dedup state

    /// Per-bucket flag: true once we've fired the critical notification, cleared
    /// when utilization drops back below `clearThreshold` (reset detection).
    private var criticalNotified: [String: Bool] = [:]
    /// Prevents repeated cookie-expired notifications during the same outage.
    private var cookieExpiredNotified = false
    private var pomodoroRequestToken = UUID()

    // MARK: - Public API

    /// Requests notification authorization. Called once at app launch (deferred).
    /// macOS shows the system permission prompt on first call; subsequent calls
    /// are no-ops if the user already granted/denied. Silently skipped when the
    /// app is not running inside a `.app` bundle (raw executable has no bundle id).
    func requestPermission() {
        guard notificationsEnabled else { return }
        let center = configuredNotificationCenter()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func schedulePomodoroCompletion(
        after seconds: Int,
        interval: PomodoroInterval,
        intervalMinutes: Int
    ) {
        guard hasValidBundleIdentifier, seconds > 0 else { return }

        let center = configuredNotificationCenter()
        let requestToken = UUID()
        let identifier = interval == .focus
            ? "pomodoro_focus_completion"
            : "pomodoro_break_completion"
        pomodoroRequestToken = requestToken
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard granted, self?.pomodoroRequestToken == requestToken else { return }

                let content = UNMutableNotificationContent()
                content.subtitle = "Pomodoro"
                switch interval {
                case .focus:
                    content.title = "🍅 Focus terminé"
                    content.body = "\(intervalMinutes) minutes de focus terminées. Pause de 5 minutes lancée."
                case .breakTime:
                    content.title = "☕ Pause terminée"
                    content.body = "Tu peux lancer la session de focus suivante."
                }
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: TimeInterval(max(1, seconds)),
                    repeats: false
                )
                center.add(UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: trigger
                ))
            }
        }
    }

    func cancelPomodoroCompletion() {
        pomodoroRequestToken = UUID()
        guard hasValidBundleIdentifier else { return }
        configuredNotificationCenter()
            .removePendingNotificationRequests(withIdentifiers: [
                "pomodoro_focus_completion",
                "pomodoro_break_completion"
            ])
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
        content.title = event.isCritical ? "🚨 Consommation critique" : "⚠️ Anomalie détectée"
        content.subtitle = event.source
        content.body = event.message
        content.sound = event.isCritical ? .defaultCritical : .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "anomaly_\(event.id)", content: content, trigger: nil
        ))
    }

    func notifyDokployDeployment(_ deployment: DokployDeployment) {
        guard notificationsEnabled, deployment.isTerminal else { return }

        let content = UNMutableNotificationContent()
        let serviceName = deployment.service?.name ?? "Service Dokploy"
        switch deployment.status {
        case "done":
            content.title = "✅ Déploiement terminé"
        case "cancelled":
            content.title = "⏹️ Déploiement annulé"
        default:
            content.title = "❌ Échec du déploiement"
        }
        content.subtitle = serviceName

        var details = [deployment.title]
        if let environment = deployment.service?.environment {
            let context = [environment.project?.name, environment.name]
                .compactMap { $0 }
                .joined(separator: " · ")
            if !context.isEmpty { details.append(context) }
        }
        if !deployment.isSuccessful,
           let message = deployment.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            details.append(message)
        }
        content.body = details.joined(separator: " — ")
        content.sound = deployment.status == "error" ? .defaultCritical : .default

        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "dokploy_\(deployment.deploymentId)",
            content: content,
            trigger: nil
        ))
    }

    /// Checks the actual OpenRouter dollar balance. Percentage utilization and
    /// spend velocity deliberately do not participate in this alert.
    func checkOpenRouterBalance(_ credits: OpenRouterCredits) {
        let defaultsKey = "openRouterLowBalanceNotified"

        if !credits.hasLowBalance {
            UserDefaults.standard.set(false, forKey: defaultsKey)
            return
        }

        guard notificationsEnabled else { return }
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        UserDefaults.standard.set(true, forKey: defaultsKey)

        let content = UNMutableNotificationContent()
        content.title = "🚨 Crédit OpenRouter faible"
        content.subtitle = "OpenRouter"
        content.body = String(
            format: "$%.2f restant — recharge conseillée.",
            credits.remaining
        )
        content.sound = .defaultCritical

        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "openrouter_low_balance",
            content: content,
            trigger: nil
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
        content.title = "🚨 Consommation critique"
        content.subtitle = label
        content.body = "\(utilization)% utilisé — la limite est presque atteinte."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "critical_\(bucket)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func configuredNotificationCenter() -> UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
