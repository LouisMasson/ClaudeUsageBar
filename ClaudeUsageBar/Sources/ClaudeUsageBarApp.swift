import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Initialize status bar first so the menu bar icon appears immediately.
        statusBarController = StatusBarController()

        // Request notification authorization after a short delay. Accessing
        // `UNUserNotificationCenter` too early in the launch sequence (before the
        // app's run loop is fully spun up) causes a segfault in release builds
        // due to the optimizer. Deferring by 1s ensures everything is ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NotificationManager.shared.requestPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup if needed
    }
}
