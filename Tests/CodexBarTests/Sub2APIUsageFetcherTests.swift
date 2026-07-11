import CodexBarCore
import Foundation
import Testing

struct Sub2APIUsageFetcherTests {
    @Test
    func `parses quota limited key usage`() throws {
        let json = """
        {
          "mode": "quota_limited",
          "isValid": true,
          "status": "active",
          "remaining": 75,
          "unit": "USD",
          "quota": {
            "limit": 100,
            "used": 25,
            "remaining": 75,
            "unit": "USD"
          },
          "rate_limits": [
            {
              "window": "5h",
              "limit": 20,
              "used": 5,
              "remaining": 15,
              "reset_at": "2026-07-11T12:30:00Z"
            },
            {
              "window": "7d",
              "limit": 200,
              "used": 40,
              "remaining": 160
            }
          ],
          "expires_at": "2026-08-01T00:00:00Z",
          "usage": {
            "today": {
              "requests": 4,
              "total_tokens": 1200,
              "actual_cost": 1.25
            },
            "total": {
              "requests": 40,
              "total_tokens": 12000,
              "actual_cost": 25
            }
          }
        }
        """

        let parsed = try Sub2APIUsageFetcher._parseSnapshotForTesting(
            Data(json.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))

        #expect(parsed.mode == "quota_limited")
        #expect(parsed.quota?.remaining == 75)
        #expect(parsed.rateLimits.count == 2)
        #expect(parsed.todayUsage?.totalTokens == 1200)

        let snapshot = parsed.toUsageSnapshot()
        #expect(snapshot.identity?.providerID == .sub2api)
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.extraRateWindows?.count == 2)
        #expect(snapshot.extraRateWindows?.first?.window.windowMinutes == 300)
        #expect(snapshot.providerCost?.used == 1.25)
        #expect(snapshot.subscriptionExpiresAt != nil)
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test
    func `parses subscription usage windows`() throws {
        let json = """
        {
          "mode": "unrestricted",
          "isValid": true,
          "planName": "Claude Team",
          "remaining": 8,
          "unit": "USD",
          "subscription": {
            "daily_usage_usd": 2,
            "weekly_usage_usd": 10,
            "monthly_usage_usd": 30,
            "daily_limit_usd": 10,
            "weekly_limit_usd": 40,
            "monthly_limit_usd": 100,
            "expires_at": "2026-08-15T00:00:00.123Z"
          }
        }
        """

        let parsed = try Sub2APIUsageFetcher._parseSnapshotForTesting(
            Data(json.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 20)
        #expect(snapshot.secondary?.usedPercent == 25)
        #expect(snapshot.tertiary?.usedPercent == 30)
        #expect(snapshot.identity?.accountOrganization == "Claude Team")
        #expect(snapshot.subscriptionExpiresAt != nil)
    }

    @Test
    func `parses unrestricted wallet balance`() throws {
        let json = """
        {
          "mode": "unrestricted",
          "isValid": true,
          "planName": "钱包余额",
          "remaining": 42.5,
          "unit": "USD",
          "balance": 42.5
        }
        """

        let parsed = try Sub2APIUsageFetcher._parseSnapshotForTesting(
            Data(json.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.primary?.resetDescription == "$42.50 remaining")
        #expect(snapshot.identity?.loginMethod == "Balance: $42.50")
    }

    @Test
    func `usage URL accepts root versioned and complete URLs`() throws {
        #expect(
            try Sub2APIUsageFetcher
                ._usageURLForTesting(baseURL: #require(URL(string: "https://api.example.com")))
                .absoluteString == "https://api.example.com/v1/usage")
        #expect(
            try Sub2APIUsageFetcher
                ._usageURLForTesting(baseURL: #require(URL(string: "https://api.example.com/v1")))
                .absoluteString == "https://api.example.com/v1/usage")
        #expect(
            try Sub2APIUsageFetcher
                ._usageURLForTesting(baseURL: #require(URL(string: "https://api.example.com/v1/usage")))
                .absoluteString == "https://api.example.com/v1/usage")
    }

    @Test
    func `fetch sends bearer API key`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://api.example.com/v1/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-group")
            let response = try #require(HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(#"{"mode":"unrestricted","isValid":true,"balance":5}"#.utf8), response)
        }

        let snapshot = try await Sub2APIUsageFetcher.fetchUsage(
            apiKey: "sk-group",
            baseURL: #require(URL(string: "https://api.example.com")),
            transport: transport)

        #expect(snapshot.balance == 5)
    }

    @Test
    func `settings allow HTTPS and loopback HTTP only`() {
        #expect(Sub2APISettingsReader.baseURL(environment: [
            Sub2APISettingsReader.baseURLEnvironmentKey: "https://api.example.com",
        ]) != nil)
        #expect(Sub2APISettingsReader.baseURL(environment: [
            Sub2APISettingsReader.baseURLEnvironmentKey: "http://127.0.0.1:8080",
        ]) != nil)
        #expect(Sub2APISettingsReader.baseURL(environment: [
            Sub2APISettingsReader.baseURLEnvironmentKey: "http://api.example.com",
        ]) == nil)
        #expect(Sub2APISettingsReader.baseURL(environment: [
            Sub2APISettingsReader.baseURLEnvironmentKey: "https://user:pass@api.example.com",
        ]) == nil)
    }

    @Test
    func `provider config projects API key and base URL`() {
        let config = ProviderConfig(
            id: .sub2api,
            apiKey: "sk-fallback",
            enterpriseHost: "https://api.example.com")
        let environment = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .sub2api,
            config: config)

        #expect(environment[Sub2APISettingsReader.apiKeyEnvironmentKey] == "sk-fallback")
        #expect(environment[Sub2APISettingsReader.baseURLEnvironmentKey] == "https://api.example.com")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .sub2api))
    }

    @Test
    func `supports labeled group API key accounts`() throws {
        let support = try #require(TokenAccountSupportCatalog.support(for: .sub2api))
        #expect(support.title == "Group API keys")
        #expect(TokenAccountSupportCatalog.envOverride(for: .sub2api, token: "sk-claude") == [
            Sub2APISettingsReader.apiKeyEnvironmentKey: "sk-claude",
        ])
    }
}
