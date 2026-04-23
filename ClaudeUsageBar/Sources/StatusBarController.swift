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
        popover.contentSize = NSSize(width: 280, height: 350)
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

        // Color driven by the projection when available (forward-looking), otherwise
        // by current utilization. Thresholds mirror the notch pill so the UI stays consistent.
        let reference = projected ?? utilization
        let color: NSColor = {
            switch reference {
            case ..<60:  return .systemGreen
            case ..<85:  return .systemOrange
            default:     return .systemRed
            }
        }()

        let icon = "◐"
        let text: String
        if let projected = projected {
            text = "\(icon) \(utilization)% → \(projected)%"
        } else {
            text = "\(icon) \(utilization)%"
        }

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

        settingsState.orgId = KeychainHelper.load(.organizationId) ?? ""
        settingsState.cookie = KeychainHelper.load(.sessionCookie) ?? ""
        settingsState.openRouterKey = KeychainHelper.load(.openRouterAPIKey) ?? ""
        settingsState.notchOverlayEnabled = UserDefaults.standard.bool(forKey: SettingsState.notchOverlayKey)

        settingsPopover = NSPopover()
        settingsPopover.contentSize = NSSize(width: 320, height: 340)
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

        guard !orgId.isEmpty, !cookie.isEmpty else {
            return
        }

        _ = KeychainHelper.save(orgId, for: .organizationId)
        _ = KeychainHelper.save(cookie, for: .sessionCookie)

        // OpenRouter key is optional — empty field removes any existing key.
        if openRouterKey.isEmpty {
            KeychainHelper.delete(.openRouterAPIKey)
        } else {
            _ = KeychainHelper.save(openRouterKey, for: .openRouterAPIKey)
        }

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
        guard let orgId = KeychainHelper.load(.organizationId),
              let cookie = KeychainHelper.load(.sessionCookie) else {
            usageState.error = "Configuration requise"
            return
        }

        usageState.isLoading = true
        usageState.error = nil

        let openRouterKey = KeychainHelper.load(.openRouterAPIKey)

        // Fire both requests concurrently.
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

        // Claude (primary) — errors populate the main error banner.
        do {
            let usage = try await claudeResult
            usageState.usage = usage
            usageState.lastUpdated = Date()
            if let util = usage.fiveHour?.utilization {
                usageState.sessionBurnRate.record(utilization: util)
            }
            updateStatusButton(
                utilization: usage.fiveHour?.utilization ?? 0,
                projected: usageState.sessionProjectedUtilization
            )
            notchOverlay.refresh()
        } catch {
            usageState.error = error.localizedDescription
            updateStatusButton(utilization: 0)
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
        }

        usageState.isLoading = false
    }

    private func startAutoRefresh() {
        // Refresh every 5 minutes
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshUsage()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
