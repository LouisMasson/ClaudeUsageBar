import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        guard CommandLine.arguments.contains("--self-test") else { return }
        do {
            try SelfTestRunner.run()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Self-test failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchAtLoginManager.migrateLegacyDevelopmentAgent()
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Initialize status bar first so the menu bar icon appears immediately.
        statusBarController = StatusBarController()

        // Notification permission is requested only after the user explicitly
        // enables alerts in Settings, never during startup.
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup if needed
    }
}
