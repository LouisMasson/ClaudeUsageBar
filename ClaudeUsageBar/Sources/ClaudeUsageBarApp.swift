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

        // Request notification authorization on the next run-loop tick, once the
        // app is fully initialized (avoids a startup crash when the system prompts
        // for notification permission before the run loop is ready).
        DispatchQueue.main.async {
            NotificationManager.shared.requestPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup if needed
    }
}
