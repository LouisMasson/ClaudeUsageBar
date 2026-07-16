import AppKit
import SwiftUI

@MainActor
class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsPopover: NSPopover!
    private var dashboardWindow: NSWindow?
    private var refreshTimer: Timer?
    private var vpsRefreshTimer: Timer?

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
        popover.contentSize = NSSize(width: 380, height: 620)
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
            onDashboard: { [weak self] in
                self?.showDashboard()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: popoverView)
    }

    func updateStatusButton(utilization: Int, projected: Int? = nil) {
        guard let button = statusItem.button else { return }

        let icon = MenuBarIcon.saved
        if let symbolName = icon.systemSymbolName,
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: icon.label) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            button.image = image.withSymbolConfiguration(configuration)
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "AI Usage Monitor — \(icon.label)"
            return
        }

        // The icon is always rendered in the standard label color (white in dark
        // mode, black in light mode) so it matches other menu bar items. The
        // utilization level is shown in detail in the popover.
        let color = NSColor.labelColor

        let text = "◐"

        let attributed = NSMutableAttributedString(string: text)
        attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: text.count))
        attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), range: NSRange(location: 0, length: text.count))

        button.image = nil
        button.imagePosition = .noImage
        button.attributedTitle = attributed
        button.toolTip = "AI Usage Monitor — \(icon.label)"
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
        settingsState.openRouterManagementKey = creds?.openRouterManagementKey ?? ""
        settingsState.clineSessionCookie = creds?.clineSessionCookie ?? ""
        settingsState.githubToken = creds?.githubToken ?? ""
        settingsState.vpsBaseURL = creds?.vpsBaseURL ?? "https://status.patronusguardian.org"
        settingsState.vpsAPIToken = creds?.vpsAPIToken ?? ""
        settingsState.claudeOAuthEnabled = UserDefaults.standard.object(forKey: SettingsState.claudeOAuthKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: SettingsState.claudeOAuthKey)
        settingsState.alertsEnabled = UserDefaults.standard.bool(forKey: SettingsState.alertsKey)
        settingsState.launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        settingsState.notchOverlayEnabled = UserDefaults.standard.bool(forKey: SettingsState.notchOverlayKey)
        settingsState.menuBarIcon = .saved

        settingsPopover = NSPopover()
        settingsPopover.contentSize = NSSize(width: 380, height: 640)
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
        let openRouterManagementKey = settingsState.openRouterManagementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let clineCookie = settingsState.clineSessionCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let githubToken = settingsState.githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let vpsBaseURL = settingsState.vpsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let vpsToken = settingsState.vpsAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasManualClaude = !orgId.isEmpty && !cookie.isEmpty
        let hasOptionalIntegration = !openRouterKey.isEmpty
            || !openRouterManagementKey.isEmpty
            || !clineCookie.isEmpty
            || !vpsToken.isEmpty
            || !githubToken.isEmpty
        guard settingsState.claudeOAuthEnabled || hasManualClaude || hasOptionalIntegration else {
            return
        }

        // A Keychain prompt is allowed only here, following an explicit Save action.
        // All background reads use kSecUseAuthenticationUIFail.
        if settingsState.claudeOAuthEnabled {
            _ = try? ClaudeOAuthService.loadCredentials(allowPrompt: true)
        }

        // All credentials are stored in a single Keychain item (one unlock prompt)
        // rather than one item per field.
        let creds = KeychainHelper.Credentials(
            organizationId: orgId,
            sessionCookie: cookie,
            openRouterAPIKey: openRouterKey,
            openRouterManagementKey: openRouterManagementKey,
            clineSessionCookie: clineCookie,
            githubToken: githubToken,
            vpsBaseURL: vpsBaseURL.isEmpty ? "https://status.patronusguardian.org" : vpsBaseURL,
            vpsAPIToken: vpsToken
        )
        _ = KeychainHelper.saveAll(creds)

        let alertsWereEnabled = UserDefaults.standard.bool(forKey: SettingsState.alertsKey)
        UserDefaults.standard.set(settingsState.notchOverlayEnabled, forKey: SettingsState.notchOverlayKey)
        UserDefaults.standard.set(settingsState.claudeOAuthEnabled, forKey: SettingsState.claudeOAuthKey)
        UserDefaults.standard.set(settingsState.alertsEnabled, forKey: SettingsState.alertsKey)
        UserDefaults.standard.set(settingsState.menuBarIcon.rawValue, forKey: MenuBarIcon.preferenceKey)
        if settingsState.alertsEnabled && !alertsWereEnabled {
            NotificationManager.shared.requestPermission()
        }
        try? LaunchAtLoginManager.setEnabled(settingsState.launchAtLoginEnabled)
        applyNotchOverlayPreference()
        updateStatusButton(
            utilization: usageState.sessionUtilization,
            projected: usageState.sessionProjectedUtilization
        )

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
        if KeychainHelper.loadAll() != nil
            || (try? ClaudeOAuthService.loadCredentials(allowPrompt: false)) != nil {
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
        let creds = KeychainHelper.loadAll() ?? KeychainHelper.Credentials()
        let oauthEnabled = UserDefaults.standard.object(forKey: SettingsState.claudeOAuthKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: SettingsState.claudeOAuthKey)
        let hasClaudeCredentials = oauthEnabled
            || (!creds.organizationId.isEmpty && !creds.sessionCookie.isEmpty)

        usageState.isLoading = true
        usageState.error = nil

        let openRouterKey = creds.openRouterAPIKey.isEmpty ? nil : creds.openRouterAPIKey
        let clineCookie = creds.clineSessionCookie.isEmpty ? nil : creds.clineSessionCookie

        // Fire all requests concurrently.
        async let claudeResult: Result<UsageResponse, Error>? = {
            guard hasClaudeCredentials else { return nil }
            do {
                return .success(try await fetchClaudeUsage(credentials: creds, oauthEnabled: oauthEnabled))
            } catch {
                return .failure(error)
            }
        }()
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
        async let codexResult: Result<CodexUsageSnapshot, Error> = {
            do {
                return .success(try await CodexUsageService.shared.fetchUsage())
            } catch {
                return .failure(error)
            }
        }()
        async let vpsResult: Void = refreshVPS(using: creds)

        // Claude is optional: a missing Claude setup no longer prevents Codex,
        // OpenRouter, Cline or VPS data from refreshing.
        switch await claudeResult {
        case .success(let usage):
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
        case .failure(let error):
            handleClaudeError(error)
        case .none:
            usageState.usage = nil
            usageState.cookieExpired = false
            usageState.error = nil
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

        switch await codexResult {
        case .success(let snapshot):
            usageState.codexUsage = snapshot
            usageState.codexError = nil
            usageState.lastUpdated = Date()
        case .failure(let error):
            // Keep the last valid values if the local Codex service is busy.
            usageState.codexError = error.localizedDescription
        }

        usageState.isLoading = false
        _ = await vpsResult
    }

    private func fetchClaudeUsage(
        credentials: KeychainHelper.Credentials,
        oauthEnabled: Bool
    ) async throws -> UsageResponse {
        if oauthEnabled {
            do {
                let oauth = try ClaudeOAuthService.loadCredentials(allowPrompt: false)
                return try await ClaudeOAuthService.shared.fetchUsage(accessToken: oauth.accessToken)
            } catch {
                // The legacy claude.ai cookie remains a deliberate fallback while
                // Anthropic's individual OAuth usage endpoint is undocumented.
                guard !credentials.organizationId.isEmpty, !credentials.sessionCookie.isEmpty else {
                    throw error
                }
            }
        }
        guard !credentials.organizationId.isEmpty, !credentials.sessionCookie.isEmpty else {
            throw ClaudeOAuthError.credentialsUnavailable
        }
        return try await ClaudeAPIService.shared.fetchUsage(
            organizationId: credentials.organizationId,
            sessionKey: credentials.sessionCookie
        )
    }

    func refreshVPS() async {
        guard let creds = KeychainHelper.loadAll() else { return }
        await refreshVPS(using: creds)
    }

    private func refreshVPS(using creds: KeychainHelper.Credentials) async {
        guard !creds.vpsAPIToken.isEmpty else {
            usageState.vpsStatus = nil
            usageState.vpsError = nil
            return
        }
        do {
            let status = try await VPSAPIService.shared.fetchStatus(
                baseURL: creds.vpsBaseURL,
                token: creds.vpsAPIToken
            )
            usageState.vpsStatus = status
            usageState.vpsError = nil
            usageState.vpsLastUpdated = Date()
            usageState.recordVPS(status)
        } catch {
            usageState.vpsError = error.localizedDescription
        }
    }

    private func showDashboard() {
        popover.performClose(nil)
        if let dashboardWindow {
            dashboardWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task {
                async let openRouterRefresh: Void = refreshOpenRouterActivity()
                async let githubRefresh: Void = refreshGitHubActivity()
                _ = await (openRouterRefresh, githubRefresh)
            }
            return
        }

        let root = DashboardView(
            usageState: usageState,
            onRefresh: { [weak self] in
                Task {
                    await self?.refreshUsage()
                    await self?.refreshOpenRouterActivity(force: true)
                    await self?.refreshGitHubActivity(force: true)
                }
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Usage Monitor — Dashboard"
        window.minSize = NSSize(width: 760, height: 520)
        window.contentViewController = NSHostingController(rootView: root)
        window.center()
        window.isReleasedWhenClosed = false
        dashboardWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            async let usageRefresh: Void = refreshUsage()
            async let activityRefresh: Void = refreshOpenRouterActivity()
            async let githubRefresh: Void = refreshGitHubActivity()
            _ = await (usageRefresh, activityRefresh, githubRefresh)
        }
    }

    /// GitHub activity is dashboard-only and cached for 15 minutes. A configured
    /// Keychain token is preferred; otherwise the existing GitHub CLI session is
    /// reused without persisting another credential.
    func refreshGitHubActivity(force: Bool = false) async {
        if !force,
           let snapshot = usageState.githubActivity,
           Date().timeIntervalSince(snapshot.fetchedAt) < 15 * 60 {
            return
        }

        let credentials = KeychainHelper.loadAll() ?? KeychainHelper.Credentials()
        usageState.isLoadingGitHubActivity = true
        usageState.githubActivityError = nil
        do {
            usageState.githubActivity = try await GitHubActivityService.shared.fetchSnapshot(
                configuredToken: credentials.githubToken
            )
        } catch {
            usageState.githubActivityError = error.localizedDescription
        }
        usageState.isLoadingGitHubActivity = false
    }

    /// OpenRouter analytics is dashboard-only and cached for 15 minutes. The
    /// lightweight credit balance remains part of the normal menu refresh.
    func refreshOpenRouterActivity(force: Bool = false) async {
        if !force,
           let snapshot = usageState.openRouterActivity,
           Date().timeIntervalSince(snapshot.fetchedAt) < 15 * 60 {
            return
        }

        let credentials = KeychainHelper.loadAll() ?? KeychainHelper.Credentials()
        let key = credentials.openRouterManagementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            usageState.openRouterActivity = nil
            usageState.openRouterActivityError = nil
            return
        }

        usageState.isLoadingOpenRouterActivity = true
        usageState.openRouterActivityError = nil
        do {
            usageState.openRouterActivity = try await OpenRouterAPIService.shared.fetchActivitySnapshot(apiKey: key)
        } catch {
            usageState.openRouterActivityError = error.localizedDescription
        }
        usageState.isLoadingOpenRouterActivity = false
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
        refreshTimer?.tolerance = 30

        vpsRefreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshVPS()
            }
        }
        vpsRefreshTimer?.tolerance = 20
    }

    deinit {
        refreshTimer?.invalidate()
        vpsRefreshTimer?.invalidate()
    }
}
