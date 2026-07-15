import Foundation
import ServiceManagement

enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: legacyPlistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            removeLegacyPlist()
            return
        }

        if enabled { try installLegacyPlist() }
        else { removeLegacyPlist() }
    }

    /// Removes the old development LaunchAgent that started the unsigned binary
    /// from `.build/release`, the source of repeated identity/Keychain prompts.
    static func migrateLegacyDevelopmentAgent() {
        guard let data = try? Data(contentsOf: legacyPlistURL),
              let text = String(data: data, encoding: .utf8),
              text.contains("/.build/release/ClaudeUsageBar") else { return }
        removeLegacyPlist()
    }

    private static var legacyPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.louismasson.ClaudeUsageBar.plist")
    }

    private static func installLegacyPlist() throws {
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/ClaudeUsageBar").path
        let plist: [String: Any] = [
            "Label": "com.louismasson.ClaudeUsageBar",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: legacyPlistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: legacyPlistURL, options: .atomic)
    }

    private static func removeLegacyPlist() {
        try? FileManager.default.removeItem(at: legacyPlistURL)
    }
}
