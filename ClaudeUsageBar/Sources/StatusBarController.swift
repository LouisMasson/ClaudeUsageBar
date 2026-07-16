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
                Task {
                    guard let self else { return }
                    async let usageRefresh: Void = self.refreshUsage()
                    async let githubRefresh: Void = self.refreshGitHubActivity(force: true)
                    _ = await (usageRefresh, githubRefresh)
                }
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
            Task { await refreshGitHubActivity() }
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
        settingsState.anomalyProfile = AnomalyProfile(
            rawValue: UserDefaults.standard.string(forKey: SettingsState.anomalyProfileKey) ?? "balanced"
        ) ?? .balanced
        settingsState.vpsAnomaliesEnabled = UserDefaults.standard.object(forKey: SettingsState.vpsAnomaliesKey) == nil
            ? true : UserDefaults.standard.bool(forKey: SettingsState.vpsAnomaliesKey)
        settingsState.modelAnomaliesEnabled = UserDefaults.standard.object(forKey: SettingsState.modelAnomaliesKey) == nil
            ? true : UserDefaults.standard.bool(forKey: SettingsState.modelAnomaliesKey)
        settingsState.launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        settingsState.notchOverlayEnabled = UserDefaults.standard.bool(forKey: SettingsState.notchOverlayKey)
        settingsState.menuBarIcon = .saved

        settingsPopover = NSPopover()
        settingsPopover.contentSize = NSSize(width: 380, height: 720)
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
        UserDefaults.standard.set(settingsState.anomalyProfile.rawValue, forKey: SettingsState.anomalyProfileKey)
        UserDefaults.standard.set(settingsState.vpsAnomaliesEnabled, forKey: SettingsState.vpsAnomaliesKey)
        UserDefaults.standard.set(settingsState.modelAnomaliesEnabled, forKey: SettingsState.modelAnomaliesKey)
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
            if !vpsToken.isEmpty {
                _ = try? await VPSAPIService.shared.updateAnomalySettings(
                    baseURL: creds.vpsBaseURL, token: vpsToken,
                    profile: settingsState.anomalyProfile,
                    vpsEnabled: settingsState.vpsAnomaliesEnabled,
                    modelEnabled: settingsState.modelAnomaliesEnabled
                )
            }
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
            notifyNewAnomalies(recordClaudeAnomalies(usage))
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
            notifyNewAnomalies(usageState.recordQuotaAnomalies(
                source: "OpenRouter", metric: "credits",
                utilization: credits.utilization, projected: nil
            ))
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
            notifyNewAnomalies(recordClineAnomalies(usage))
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
            notifyNewAnomalies(recordCodexAnomalies(snapshot))
        case .failure(let error):
            // Keep the last valid values if the local Codex service is busy.
            usageState.codexError = error.localizedDescription
        }

        usageState.isLoading = false
        _ = await vpsResult
        await refreshOpenRouterActivity()
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
            await syncVPSAnomalies(using: creds)
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

    /// OpenRouter analytics is cached for 15 minutes and refreshes in the
    /// background when a management key exists, independently of the dashboard.
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
            let snapshot = try await OpenRouterAPIService.shared.fetchActivitySnapshot(apiKey: key)
            usageState.openRouterActivity = snapshot
            notifyNewAnomalies(recordOpenRouterActivityAnomalies(snapshot))
        } catch {
            usageState.openRouterActivityError = error.localizedDescription
        }
        usageState.isLoadingOpenRouterActivity = false
    }

    private func notifyNewAnomalies(_ events: [AnomalyEvent]) {
        events.forEach { NotificationManager.shared.notifyAnomaly($0) }
    }

    private func recordClaudeAnomalies(_ usage: UsageResponse) -> [AnomalyEvent] {
        var opened: [AnomalyEvent] = []
        if let bucket = usage.fiveHour {
            opened += usageState.recordQuotaAnomalies(source: "Claude", metric: "session_5h", utilization: bucket.utilization, projected: usageState.sessionProjectedUtilization)
        }
        if let bucket = usage.sevenDay {
            opened += usageState.recordQuotaAnomalies(source: "Claude", metric: "weekly", utilization: bucket.utilization, projected: usageState.weeklyProjectedUtilization)
        }
        if let bucket = usage.sevenDaySonnet {
            opened += usageState.recordQuotaAnomalies(source: "Claude Sonnet", metric: "weekly", utilization: bucket.utilization, projected: usageState.sonnetProjectedUtilization)
        }
        if let bucket = usage.sevenDayOmelette {
            opened += usageState.recordQuotaAnomalies(source: "Claude Design", metric: "weekly", utilization: bucket.utilization, projected: usageState.designProjectedUtilization)
        }
        return opened
    }

    private func recordClineAnomalies(_ usage: ClineUsageResponse) -> [AnomalyEvent] {
        var opened: [AnomalyEvent] = []
        if let bucket = usage.fiveHour {
            opened += usageState.recordQuotaAnomalies(source: "Cline", metric: "session_5h", utilization: bucket.percentUsed, projected: usageState.clineFiveHourProjectedUtilization)
        }
        if let bucket = usage.weekly {
            opened += usageState.recordQuotaAnomalies(source: "Cline", metric: "weekly", utilization: bucket.percentUsed, projected: usageState.clineWeeklyProjectedUtilization)
        }
        if let bucket = usage.monthly {
            opened += usageState.recordQuotaAnomalies(source: "Cline", metric: "monthly", utilization: bucket.percentUsed, projected: usageState.clineMonthlyProjectedUtilization)
        }
        return opened
    }

    private func recordCodexAnomalies(_ snapshot: CodexUsageSnapshot) -> [AnomalyEvent] {
        var opened: [AnomalyEvent] = []
        for window in snapshot.windows {
            opened += usageState.recordQuotaAnomalies(
                source: "Codex", metric: "window_\(window.windowDurationMins ?? 0)",
                utilization: window.usedPercent, projected: nil
            )
        }
        if let buckets = snapshot.tokenUsage.dailyUsageBuckets, !buckets.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let todayKey = formatter.string(from: Date())
            let today = buckets.first(where: { $0.startDate == todayKey })?.tokens ?? buckets.first?.tokens ?? 0
            let previous = buckets.filter { $0.startDate != todayKey }.map { Double($0.tokens) }
            opened += usageState.recordDailyAnomaly(
                source: "Codex", metric: "daily_tokens", todayValue: Double(today), previousDays: previous
            )
        }
        return opened
    }

    private func recordOpenRouterActivityAnomalies(_ snapshot: OpenRouterActivitySnapshot) -> [AnomalyEvent] {
        let summary = snapshot.summary(days: 7)
        guard let today = summary.daily.last else { return [] }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let isCompleteDay = today.date != formatter.string(from: Date())
        let previous = summary.daily.dropLast().map(\.spend)
        let todayModels = snapshot.modelActivities.filter { $0.date == today.date }.sorted { $0.spend > $1.spend }
        let todayKeys = snapshot.keyActivities.filter { $0.date == today.date }.sorted { $0.spend > $1.spend }
        return usageState.recordDailyAnomaly(
            source: "OpenRouter", metric: "daily_spend", todayValue: today.spend,
            previousDays: previous, attribution: todayModels.first?.name ?? todayKeys.first?.name,
            isCompleteDay: isCompleteDay
        )
    }

    private func syncVPSAnomalies(using creds: KeychainHelper.Credentials) async {
        let syncKey = "lastVPSAnomalySync"
        let previousTimestamp = UserDefaults.standard.double(forKey: syncKey)
        let since = previousTimestamp > 0
            ? Date(timeIntervalSince1970: previousTimestamp - 300)
            : Date().addingTimeInterval(-7 * 24 * 3600)
        do {
            let response = try await VPSAPIService.shared.fetchAnomalies(
                baseURL: creds.vpsBaseURL, token: creds.vpsAPIToken, since: since
            )
            let firstSync = previousTimestamp == 0
            let newlyOpened = usageState.mergeServerAnomalies(response.events)
            usageState.anomalySyncError = nil
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: syncKey)
            if firstSync {
                if let critical = newlyOpened.filter({ $0.isCritical }).max(by: { $0.startedAt < $1.startedAt }) {
                    NotificationManager.shared.notifyAnomaly(critical)
                }
            } else {
                notifyNewAnomalies(newlyOpened)
            }
        } catch {
            usageState.anomalySyncError = error.localizedDescription
        }
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
