import AppKit
import SwiftUI

@MainActor
class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsPopover: NSPopover!
    private var refreshTimer: Timer?

    let usageState = UsageState()
    let settingsState = SettingsState()
    private lazy var notchOverlay = NotchOverlayController(usageState: usageState)

    override init() {
        super.init()
        setupStatusItem()
        setupPopover()
        applyNotchOverlayPreference()
        loadCredentialsAndRefresh()
        startAutoRefresh()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateStatusButton(utilization: 0)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 470)
        popover.behavior = .transient
        popover.animates = true

        let popoverView = PopoverView(
            usageState: usageState,
            onRefresh: { [weak self] in
                Task { await self?.refreshUsage() }
            },
            onSettings: { [weak self] in
                self?.showSettings()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: popoverView)
    }

    func updateStatusButton(utilization: Int, projected: Int? = nil) {
        guard let button = statusItem.button else { return }

        // The icon is always rendered in the standard label color (white in dark
        // mode, black in light mode) so it matches other menu bar items. The
        // utilization level is shown in detail in the popover.
        let color = NSColor.labelColor

        let text = "◐"

        let attributed = NSMutableAttributedString(string: text)
        attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: text.count))
        attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), range: NSRange(location: 0, length: text.count))

        button.attributedTitle = attributed
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            // Close settings popover if open
            settingsPopover?.performClose(nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showSettings() {
        popover.performClose(nil)

        let creds = KeychainHelper.loadAll()
        settingsState.orgId = creds?.organizationId ?? ""
        settingsState.cookie = creds?.sessionCookie ?? ""
        settingsState.openRouterKey = creds?.openRouterAPIKey ?? ""
        settingsState.clineSessionCookie = creds?.clineSessionCookie ?? ""
        settingsState.notchOverlayEnabled = UserDefaults.standard.bool(forKey: SettingsState.notchOverlayKey)

        settingsPopover = NSPopover()
        settingsPopover.contentSize = NSSize(width: 320, height: 420)
        settingsPopover.behavior = .applicationDefined  // Ne se ferme pas automatiquement
        settingsPopover.animates = true

        let settingsView = SettingsViewWrapper(
            settingsState: settingsState,
            onSave: { [weak self] in
                self?.saveSettings()
            },
            onCancel: { [weak self] in
                self?.settingsPopover?.performClose(nil)
            }
        )

        settingsPopover.contentViewController = NSHostingController(rootView: settingsView)

        if let button = statusItem.button {
            settingsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func saveSettings() {
        let orgId = settingsState.orgId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = settingsState.cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let openRouterKey = settingsState.openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let clineCookie = settingsState.clineSessionCookie.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !orgId.isEmpty, !cookie.isEmpty else {
            return
        }

        // All credentials are stored in a single Keychain item (one unlock prompt)
        // rather than one item per field.
        let creds = KeychainHelper.Credentials(
            organizationId: orgId,
            sessionCookie: cookie,
            openRouterAPIKey: openRouterKey,
            clineSessionCookie: clineCookie
        )
        _ = KeychainHelper.saveAll(creds)

        UserDefaults.standard.set(settingsState.notchOverlayEnabled, forKey: SettingsState.notchOverlayKey)
        applyNotchOverlayPreference()

        settingsPopover?.performClose(nil)

        Task {
            await refreshUsage()
        }
    }

    private func applyNotchOverlayPreference() {
        if settingsState.notchOverlayEnabled {
            notchOverlay.enable()
            notchOverlay.refresh()
        } else {
            notchOverlay.disable()
        }
    }

    private func loadCredentialsAndRefresh() {
        if KeychainHelper.hasCredentials() {
            Task {
                await refreshUsage()
            }
        } else {
            // Show settings on first launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showSettings()
            }
        }
    }

    func refreshUsage() async {
        guard let creds = KeychainHelper.loadAll(),
              !creds.organizationId.isEmpty,
              !creds.sessionCookie.isEmpty else {
            usageState.error = "Configuration requise"
            return
        }

        usageState.isLoading = true
        usageState.error = nil

        let orgId = creds.organizationId
        let cookie = creds.sessionCookie
        let openRouterKey = creds.openRouterAPIKey.isEmpty ? nil : creds.openRouterAPIKey
        let clineCookie = creds.clineSessionCookie.isEmpty ? nil : creds.clineSessionCookie

        // Fire all requests concurrently.
        async let claudeResult = ClaudeAPIService.shared.fetchUsage(
            organizationId: orgId,
            sessionKey: cookie
        )
        async let openRouterResult: Result<OpenRouterCredits, Error>? = {
            guard let key = openRouterKey else { return nil }
            do {
                let credits = try await OpenRouterAPIService.shared.fetchCredits(apiKey: key)
                return .success(credits)
            } catch {
                return .failure(error)
            }
        }()
        async let clineResult: Result<ClineUsageResponse, Error>? = {
            guard let cookie = clineCookie else { return nil }
            do {
                let usage = try await ClineAPIService.shared.fetchUsage(sessionCookie: cookie)
                return .success(usage)
            } catch {
                return .failure(error)
            }
        }()

        // Claude (primary) — errors are triaged into cookie-expired / offline /
        // hard-error so the UI can react appropriately.
        do {
            let usage = try await claudeResult
            usageState.usage = usage
            usageState.lastUpdated = Date()
            usageState.cookieExpired = false
            usageState.isOffline = false
            NotificationManager.shared.clearCookieExpired()
            // Record a sample per bucket so every indicator can project forward.
            if let util = usage.fiveHour?.utilization {
                usageState.sessionBurnRate.record(utilization: util)
            }
            if let util = usage.sevenDay?.utilization {
                usageState.weeklyBurnRate.record(utilization: util)
            }
            if let util = usage.sevenDaySonnet?.utilization {
                usageState.sonnetBurnRate.record(utilization: util)
            }
            if let util = usage.sevenDayOmelette?.utilization {
                usageState.designBurnRate.record(utilization: util)
            }
            updateStatusButton(
                utilization: usage.fiveHour?.utilization ?? 0,
                projected: usageState.sessionProjectedUtilization
            )
            notchOverlay.refresh()
            // Critical-threshold notification (90% on the 5h session).
            NotificationManager.shared.checkCriticalThreshold(
                claude5h: usage.fiveHour?.utilization ?? 0,
                cline5h: usageState.clineFiveHourUtilization
            )
        } catch {
            handleClaudeError(error)
        }

        // OpenRouter (optional) — isolated from Claude's state.
        switch await openRouterResult {
        case .none:
            usageState.openRouterCredits = nil
            usageState.openRouterError = nil
        case .success(let credits):
            usageState.openRouterCredits = credits
            usageState.openRouterError = nil
        case .failure(let error):
            usageState.openRouterCredits = nil
            usageState.openRouterError = error.localizedDescription
            if case APIError.unauthorized = error {
                NotificationManager.shared.notifyCookieExpired(service: "OpenRouter")
            }
        }

        // Cline Pass (optional) — isolated from Claude's state.
        switch await clineResult {
        case .none:
            usageState.clineUsage = nil
            usageState.clineError = nil
        case .success(let usage):
            usageState.clineUsage = usage
            usageState.clineError = nil
            // Record a sample per rolling window so every indicator can project forward.
            if let util = usage.fiveHour?.percentUsed {
                usageState.clineFiveHourBurnRate.record(utilization: util)
            }
            if let util = usage.weekly?.percentUsed {
                usageState.clineWeeklyBurnRate.record(utilization: util)
            }
            if let util = usage.monthly?.percentUsed {
                usageState.clineMonthlyBurnRate.record(utilization: util)
            }
            // Re-evaluate critical threshold now that Cline 5h is fresh.
            NotificationManager.shared.checkCriticalThreshold(
                claude5h: usageState.sessionUtilization,
                cline5h: usage.fiveHour?.percentUsed ?? 0
            )
        case .failure(let error):
            usageState.clineUsage = nil
            usageState.clineError = error.localizedDescription
            if case APIError.unauthorized = error {
                NotificationManager.shared.notifyCookieExpired(service: "Cline Pass")
            }
        }

        usageState.isLoading = false
    }

    /// Triages a Claude API error into one of three UI states:
    /// - **Cookie expired (401/403)** → `cookieExpired = true`, popover shows a
    ///   "session expired" view with a shortcut to Settings.
    /// - **Transient error (network/5xx) + cached data** → `isOffline = true`,
    ///   popover keeps showing the last known values with a discrete badge.
    /// - **Transient error + no cache** → `error` message, ErrorView is shown.
    private func handleClaudeError(_ error: Error) {
        if case APIError.unauthorized = error {
            usageState.cookieExpired = true
            usageState.isOffline = false
            usageState.error = nil
            NotificationManager.shared.notifyCookieExpired(service: "Claude")
            updateStatusButton(utilization: 0)
            return
        }

        // Transient (network / 5xx / invalid response).
        if usageState.usage != nil {
            // We have cached data — keep it, flag as offline.
            usageState.isOffline = true
            usageState.cookieExpired = false
            usageState.error = nil
        } else {
            // No cache yet — show the error banner.
            usageState.isOffline = false
            usageState.cookieExpired = false
            usageState.error = error.localizedDescription
        }
        updateStatusButton(utilization: usageState.sessionUtilization)
    }

    private func startAutoRefresh() {
        // Refresh every 5 minutes
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshUsage()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
