import AppKit
import SwiftUI

/// Floating usage overlay pinned under the Mac notch (or top-center on non-notched
/// Macs). Appears when the cursor enters a hot zone around the notch, fades out
/// when the cursor leaves. Requested in issue #1.
@MainActor
final class NotchOverlayController {
    private let usageState: UsageState
    private var panel: NotchPanel?
    private var hostingView: NSHostingView<NotchOverlayView>?
    private var mouseMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?

    // UX constants — tuned to feel natural around the notch without being trigger-happy.
    private let overlaySize = CGSize(width: 240, height: 58)
    private let hotZoneHeight: CGFloat = 40         // menu-bar height on Apple Silicon
    private let hotZoneExtraWidth: CGFloat = 60     // padding on each side of the notch
    private let hideDelay: TimeInterval = 0.6

    init(usageState: UsageState) {
        self.usageState = usageState
    }

    deinit {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func enable() {
        guard panel == nil else { return }
        buildPanel()
        installMouseMonitor()
    }

    func disable() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        hideWorkItem?.cancel()
    }

    /// Rebuilds the SwiftUI view so the overlay reflects the latest usage.
    func refresh() {
        guard let hostingView else { return }
        hostingView.rootView = NotchOverlayView(usageState: usageState)
    }

    // MARK: - Panel

    private func buildPanel() {
        let view = NotchOverlayView(usageState: usageState)
        let hosting = NSHostingView(rootView: view)
        hostingView = hosting

        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: overlaySize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.alphaValue = 0
        positionPanel(panel)
        self.panel = panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let origin = NSPoint(
            x: frame.midX - overlaySize.width / 2,
            y: frame.maxY - overlaySize.height - topInset(for: screen) - 4
        )
        panel.setFrameOrigin(origin)
    }

    private func topInset(for screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top
        }
        return 0
    }

    // MARK: - Mouse tracking

    private func installMouseMonitor() {
        // Global monitor so we catch moves even when the app is not active.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMoved(at: NSEvent.mouseLocation)
            }
        }
    }

    private func handleMouseMoved(at location: NSPoint) {
        guard let screen = NSScreen.main else { return }
        if hotZone(for: screen).contains(location) {
            showOverlay()
        } else if let panel = panel, panel.alphaValue > 0 {
            scheduleHide()
        }
    }

    /// Rectangle centered on the notch (or top-center) where a hover opens the overlay.
    private func hotZone(for screen: NSScreen) -> NSRect {
        let notchWidth: CGFloat = 220
        let width = notchWidth + hotZoneExtraWidth * 2
        let height = max(hotZoneHeight, topInset(for: screen))
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func showOverlay() {
        guard let panel else { return }
        hideWorkItem?.cancel()
        if !panel.isVisible {
            positionPanel(panel)
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideOverlay()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    private func hideOverlay() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }
}

/// Non-activating panel so showing the overlay never steals focus from the active app.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
