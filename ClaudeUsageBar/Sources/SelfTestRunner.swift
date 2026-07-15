import Foundation

enum SelfTestRunner {
    static func run() throws {
        try testOAuthUsageDecoding()
        try testVPSStatusDecoding()
        try testLegacyCredentialMigration()
        FileHandle.standardOutput.write(Data("ClaudeUsageBar self-tests: OK\n".utf8))
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "ClaudeUsageBarSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func testOAuthUsageDecoding() throws {
        let json = #"{"five_hour":{"utilization":37.4,"resets_at":"2026-07-15T22:00:00Z"},"seven_day":{"utilization":26,"resets_at":"2026-07-20T22:00:00Z"},"seven_day_sonnet":null,"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}"#
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        try require(usage.fiveHour?.utilization == 37, "OAuth floating utilization")
        try require(usage.sevenDay?.utilization == 26, "OAuth weekly utilization")
        try require(usage.sevenDaySonnet == nil, "OAuth nullable buckets")
    }

    private static func testVPSStatusDecoding() throws {
        let json = #"{"schema_version":1,"status":"ok","updated_at":"2026-07-15T20:00:00Z","vps":{"cpu_percent":12.5,"ram_percent":41.2,"disk_percent":73.0,"uptime":"2 days"},"sites":{"healthy":2,"total":2,"items":[{"name":"status.example.org","status":"up","detail":"HTTP 200"}]},"services":{"healthy":1,"total":1,"items":[{"name":"Traefik","status":"running","detail":null}]}}"#
        let status = try JSONDecoder().decode(VPSMenuStatus.self, from: Data(json.utf8))
        try require(status.isHealthy, "VPS global status")
        try require(status.sites.healthy == 2, "VPS sites availability")
        try require(status.services.items.first?.name == "Traefik", "VPS service list")
    }

    private static func testLegacyCredentialMigration() throws {
        let json = #"{"organizationId":"org","sessionCookie":"sessionKey=value","openRouterAPIKey":"","clineSessionCookie":""}"#
        let credentials = try JSONDecoder().decode(KeychainHelper.Credentials.self, from: Data(json.utf8))
        try require(credentials.vpsBaseURL == "https://status.patronusguardian.org", "Legacy VPS URL default")
        try require(credentials.vpsAPIToken.isEmpty, "Legacy VPS token default")
    }
}
