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

    override init() {
        super.init()
        setupStatusItem()
        setupPopover()
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

    func updateStatusButton(utilization: Int) {
        guard let button = statusItem.button else { return }

        // Create attributed string with progress bar
        // Visual bar calculation (for future use)
        _ = Int(Double(40) * Double(utilization) / 100.0)

        let color: NSColor = .systemOrange

        // Use a simple text representation with percentage
        let icon = "◐"  // Half-filled circle icon
        let text = "\(icon) \(utilization)%"

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

        settingsPopover = NSPopover()
        settingsPopover.contentSize = NSSize(width: 320, height: 280)
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

        guard !orgId.isEmpty, !cookie.isEmpty else {
            print("DEBUG: orgId ou cookie vide")
            return
        }

        let savedOrg = KeychainHelper.save(orgId, for: .organizationId)
        let savedCookie = KeychainHelper.save(cookie, for: .sessionCookie)
        print("DEBUG: Saved orgId=\(savedOrg), cookie=\(savedCookie)")

        settingsPopover?.performClose(nil)

        Task {
            await refreshUsage()
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

        do {
            let usage = try await ClaudeAPIService.shared.fetchUsage(
                organizationId: orgId,
                sessionKey: cookie
            )

            usageState.usage = usage
            usageState.lastUpdated = Date()
            usageState.isLoading = false

            // Update status bar with session utilization
            updateStatusButton(utilization: usage.fiveHour?.utilization ?? 0)

        } catch {
            usageState.isLoading = false
            usageState.error = error.localizedDescription
            updateStatusButton(utilization: 0)
        }
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
