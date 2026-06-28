import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthDelegatedRefreshLinuxTests {
    private actor AsyncCounter {
        private var value = 0

        func increment() -> Int {
            self.value += 1
            return self.value
        }

        func current() -> Int {
            self.value
        }
    }

    private actor TokenCapture {
        private var token: String?

        func set(_ token: String) {
            self.token = token
        }

        func get() -> String? {
            self.token
        }
    }

    @Test
    func cliOAuthStrategyDoesNotDelegateRefreshForExpiredCache() async throws {
        let delegatedCounter = AsyncCounter()
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }
                ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting() }

                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        let tempDir = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: tempDir) }

                        let fileURL = tempDir.appendingPathComponent("credentials.json")
                        await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                            ClaudeOAuthCredentialsStore.invalidateCache()
                            let expiredData = self.makeCredentialsData(
                                accessToken: "expired-token",
                                expiresAt: Date(timeIntervalSinceNow: -3600))
                            let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                            let cacheEntry = ClaudeOAuthCredentialsStore.CacheEntry(
                                data: expiredData,
                                storedAt: Date(),
                                owner: .claudeCLI)
                            KeychainCacheStore.store(key: cacheKey, entry: cacheEntry)
                            defer { KeychainCacheStore.clear(key: cacheKey) }

                            let keychainOverrideStore = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore(
                                data: Data(),
                                fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                                    modifiedAt: 1,
                                    createdAt: 1,
                                    persistentRefHash: "test"))
                            let delegatedOverride: (@Sendable (
                                Date,
                                TimeInterval,
                                [String: String]) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? =
                                { _, _, _ in
                                    _ = await delegatedCounter.increment()
                                    return .attemptedSucceeded
                                }

                            do {
                                _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                                    try await ProviderInteractionContext.$current.withValue(.background) {
                                        try await ClaudeOAuthCredentialsStore
                                            .withMutableClaudeKeychainOverrideStoreForTesting(keychainOverrideStore) {
                                                try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride
                                                    .withValue(delegatedOverride) {
                                                        try await ClaudeOAuthFetchStrategy()
                                                            .fetch(self.makeContext(runtime: .cli))
                                                    }
                                            }
                                    }
                                }
                                Issue.record("Expected CLI OAuth strategy to fail without delegated refresh")
                            } catch let error as ClaudeUsageError {
                                guard case let .oauthFailed(message) = error else {
                                    Issue.record("Expected ClaudeUsageError.oauthFailed, got \(error)")
                                    return
                                }
                                #expect(message.contains("delegated Claude CLI refresh did not recover"))
                            } catch {
                                Issue.record("Expected ClaudeUsageError, got \(error)")
                            }

                            #expect(await delegatedCounter.current() == 0)
                        }
                    }
                }
            }
        }
    }

    @Test
    func appOAuthStrategyPreservesUserInitiatedDelegatedRefresh() async throws {
        let delegatedCounter = AsyncCounter()
        let usageResponse = try Self.makeOAuthUsageResponse()
        let tokenCapture = TokenCapture()
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }
                ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting() }

                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        let tempDir = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: tempDir) }

                        let fileURL = tempDir.appendingPathComponent("credentials.json")
                        let result = try await ClaudeOAuthCredentialsStore
                            .withCredentialsURLOverrideForTesting(fileURL) {
                                ClaudeOAuthCredentialsStore.invalidateCache()
                                let expiredData = self.makeCredentialsData(
                                    accessToken: "expired-token",
                                    expiresAt: Date(timeIntervalSinceNow: -3600))
                                let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                                let cacheEntry = ClaudeOAuthCredentialsStore.CacheEntry(
                                    data: expiredData,
                                    storedAt: Date(),
                                    owner: .claudeCLI)
                                KeychainCacheStore.store(key: cacheKey, entry: cacheEntry)
                                defer { KeychainCacheStore.clear(key: cacheKey) }

                                let stubFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                                    modifiedAt: 1,
                                    createdAt: 1,
                                    persistentRefHash: "test")
                                let keychainOverrideStore = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore(
                                    data: Data(),
                                    fingerprint: stubFingerprint)
                                let freshData = self.makeCredentialsData(
                                    accessToken: "fresh-token",
                                    expiresAt: Date(timeIntervalSinceNow: 3600))
                                let fetchOverride: (@Sendable (String) async throws -> OAuthUsageResponse)? = {
                                    token in
                                    await tokenCapture.set(token)
                                    return usageResponse
                                }
                                let delegatedOverride: (@Sendable (
                                    Date,
                                    TimeInterval,
                                    [String: String]) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? =
                                    { _, _, _ in
                                        keychainOverrideStore.data = freshData
                                        keychainOverrideStore.fingerprint = stubFingerprint
                                        _ = await delegatedCounter.increment()
                                        return .attemptedSucceeded
                                    }

                                return try await ClaudeOAuthKeychainPromptPreference
                                    .withTaskOverrideForTesting(.always) {
                                        try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                            try await ClaudeOAuthCredentialsStore
                                                .withMutableClaudeKeychainOverrideStoreForTesting(
                                                    keychainOverrideStore)
                                                {
                                                    try await ClaudeUsageFetcher.$fetchOAuthUsageOverride
                                                        .withValue(fetchOverride) {
                                                            try await ClaudeUsageFetcher
                                                                .$delegatedRefreshAttemptOverride
                                                                .withValue(delegatedOverride) {
                                                                    try await ClaudeOAuthFetchStrategy()
                                                                        .fetch(self.makeContext(runtime: .app))
                                                                }
                                                        }
                                                }
                                        }
                                    }
                            }

                        #expect(await delegatedCounter.current() == 1)
                        #expect(await tokenCapture.get() == "fresh-token")
                        #expect(result.usage.primary?.usedPercent == 7)
                        #expect(result.usage.secondary?.usedPercent == 21)
                    }
                }
            }
        }
    }

    @Test
    func disabledDelegatedRefreshDoesNotTouchClaudeCLIForExpiredCache() async throws {
        let delegatedCounter = AsyncCounter()
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }
                ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting() }

                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        let tempDir = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: tempDir) }

                        let fileURL = tempDir.appendingPathComponent("credentials.json")
                        await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                            ClaudeOAuthCredentialsStore.invalidateCache()
                            let expiredData = self.makeCredentialsData(
                                accessToken: "expired-token",
                                expiresAt: Date(timeIntervalSinceNow: -3600))
                            let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                            let cacheEntry = ClaudeOAuthCredentialsStore.CacheEntry(
                                data: expiredData,
                                storedAt: Date(),
                                owner: .claudeCLI)
                            KeychainCacheStore.store(key: cacheKey, entry: cacheEntry)
                            defer { KeychainCacheStore.clear(key: cacheKey) }

                            let keychainOverrideStore = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore(
                                data: Data(),
                                fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                                    modifiedAt: 1,
                                    createdAt: 1,
                                    persistentRefHash: "test"))
                            let fetcher = ClaudeUsageFetcher(
                                browserDetection: BrowserDetection(cacheTTL: 0),
                                environment: [:],
                                dataSource: .oauth,
                                allowDelegatedRefresh: false,
                                allowBackgroundDelegatedRefresh: true)
                            let delegatedOverride: (@Sendable (
                                Date,
                                TimeInterval,
                                [String: String]) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? =
                                { _, _, _ in
                                    _ = await delegatedCounter.increment()
                                    return .attemptedSucceeded
                                }

                            do {
                                _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                                    try await ProviderInteractionContext.$current.withValue(.background) {
                                        try await ClaudeOAuthCredentialsStore
                                            .withMutableClaudeKeychainOverrideStoreForTesting(keychainOverrideStore) {
                                                try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride
                                                    .withValue(delegatedOverride) {
                                                        try await fetcher.loadLatestUsage(model: "sonnet")
                                                    }
                                            }
                                    }
                                }
                                Issue.record("Expected expired OAuth fetch to fail without delegated refresh")
                            } catch let error as ClaudeUsageError {
                                guard case let .oauthFailed(message) = error else {
                                    Issue.record("Expected ClaudeUsageError.oauthFailed, got \(error)")
                                    return
                                }
                                #expect(message.contains("delegated Claude CLI refresh did not recover"))
                            } catch {
                                Issue.record("Expected ClaudeUsageError, got \(error)")
                            }

                            #expect(await delegatedCounter.current() == 0)
                        }
                    }
                }
            }
        }
    }

    private func makeCredentialsData(accessToken: String, expiresAt: Date) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]
          }
        }
        """
        return Data(json.utf8)
    }

    private static func makeOAuthUsageResponse() throws -> OAuthUsageResponse {
        let json = """
        {
          "five_hour": { "utilization": 7, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day": { "utilization": 21, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        return try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
    }

    private func makeContext(runtime: ProviderRuntime) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: .oauth,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}
