import Foundation

enum SelfTestRunner {
    static func run() throws {
        try testOAuthUsageDecoding()
        try testVPSStatusDecoding()
        try testOpenRouterActivitySummary()
        try testOpenRouterAnalyticsDecoding()
        try testCodexUsageDecoding()
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
        let json = #"{"schema_version":2,"status":"ok","updated_at":"2026-07-15T20:00:00Z","vps":{"cpu_percent":12.5,"ram_percent":41.2,"ram_available_gb":6.4,"swap_percent":8.1,"swap_used_gb":0.8,"disk_percent":73.0,"disk_free_gb":31.2,"load_1":0.4,"load_5":0.3,"load_15":0.2,"cores":6,"uptime":"2 days"},"sites":{"healthy":2,"total":2,"items":[{"name":"louismasson.me","status":"up","detail":"HTTP 200","url":"https://louismasson.me","http_status":200,"latency_ms":84,"tls_days_remaining":76,"analytics":{"today":{"visitors":2,"visits":2,"pageviews":3},"7d":{"visitors":9,"visits":10,"pageviews":15},"30d":{"visitors":46,"visits":47,"pageviews":62}}}]},"services":{"healthy":1,"total":1,"items":[{"name":"Traefik","status":"running","detail":"Up 2 days","image":"traefik:v3","created_at":"2026-07-13T20:00:00Z"}]}}"#
        let status = try JSONDecoder().decode(VPSMenuStatus.self, from: Data(json.utf8))
        try require(status.isHealthy, "VPS global status")
        try require(status.sites.healthy == 2, "VPS sites availability")
        try require(status.services.items.first?.name == "Traefik", "VPS service list")
        try require(status.vps.swapPercent == 8.1, "VPS swap metric")
        try require(status.sites.items.first?.analytics?.thirtyDays.visitors == 46, "Plausible visitors")
    }

    private static func testOpenRouterActivitySummary() throws {
        let json = #"{"data":[{"byok_usage_inference":0,"completion_tokens":500,"date":"2026-07-14","endpoint_id":"ep-1","model":"anthropic/claude-sonnet-4","model_permaslug":"anthropic/claude-sonnet-4","prompt_tokens":1000,"provider_name":"Anthropic","reasoning_tokens":100,"requests":2,"usage":0.15},{"byok_usage_inference":0.02,"completion_tokens":1000,"date":"2026-07-15","endpoint_id":"ep-2","model":"openai/gpt-5","model_permaslug":null,"prompt_tokens":2000,"provider_name":"OpenAI","reasoning_tokens":200,"requests":3,"usage":0.30}]}"#
        let response = try JSONDecoder().decode(OpenRouterActivityResponse.self, from: Data(json.utf8))
        let summary = OpenRouterActivitySummary(items: response.data, keyActivities: [], days: 7)
        try require(summary.requests == 5, "OpenRouter request aggregation")
        try require(summary.tokens == 4_500, "OpenRouter token aggregation")
        try require(abs(summary.spend - 0.45) < 0.0001, "OpenRouter spend aggregation")
        try require(summary.topModels.first?.name == "openai/gpt-5", "OpenRouter model ranking")
    }

    private static func testOpenRouterAnalyticsDecoding() throws {
        let json = #"{"data":{"data":[{"created_at__day":"2026-07-14","model":"anthropic/claude-sonnet-4","total_usage":0.42,"request_count":"12","tokens_total":"9800","cache_hit_rate":0.75}],"metadata":{"truncated":false}}}"#
        let response = try JSONDecoder().decode(OpenRouterAnalyticsResponse.self, from: Data(json.utf8))
        let row = try requireValue(response.data.data.first, "OpenRouter analytics row")
        try require(row.date == "2026-07-14", "OpenRouter analytics date")
        try require(row.requests == 12, "OpenRouter string request count")
        try require(row.tokens == 9_800, "OpenRouter string token count")
        try require(row.cacheHitRate == 0.75, "OpenRouter cache hit rate")
    }

    private static func testCodexUsageDecoding() throws {
        let rateJSON = #"{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":19,"windowDurationMins":10080,"resetsAt":1784740062},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"plus"},"rateLimitsByLimitId":null}"#
        let rates = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: Data(rateJSON.utf8))
        try require(rates.codex.primary?.usedPercent == 19, "Codex rate limit percent")
        try require(rates.codex.primary?.label == "Hebdomadaire", "Codex rate limit label")

        let usageJSON = #"{"summary":{"lifetimeTokens":49907696,"peakDailyTokens":16708267,"longestRunningTurnSec":703,"currentStreakDays":0,"longestStreakDays":3},"dailyUsageBuckets":[{"startDate":"2026-07-13","tokens":2662448}]}"#
        let usage = try JSONDecoder().decode(CodexTokenUsageResponse.self, from: Data(usageJSON.utf8))
        try require(usage.summary.lifetimeTokens == 49_907_696, "Codex lifetime tokens")
        try require(usage.dailyUsageBuckets?.first?.tokens == 2_662_448, "Codex daily tokens")
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw NSError(domain: "ClaudeUsageBarSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return value
    }

    private static func testLegacyCredentialMigration() throws {
        let json = #"{"organizationId":"org","sessionCookie":"sessionKey=value","openRouterAPIKey":"","clineSessionCookie":""}"#
        let credentials = try JSONDecoder().decode(KeychainHelper.Credentials.self, from: Data(json.utf8))
        try require(credentials.vpsBaseURL == "https://status.patronusguardian.org", "Legacy VPS URL default")
        try require(credentials.vpsAPIToken.isEmpty, "Legacy VPS token default")
        try require(credentials.openRouterManagementKey.isEmpty, "Legacy OpenRouter management key default")
        try require(credentials.githubToken.isEmpty, "Legacy GitHub token default")
    }
}
