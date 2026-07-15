import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CursorImportedSessionScanningTests {
    private final class LockedArray<Element>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Element] = []

        func append(_ value: Element) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.values.append(value)
        }

        func snapshot() -> [Element] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.values
        }
    }

    @Test
    func `browser login candidates return every valid unique session without committing cache`() async throws {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let strictPersonal = Self.makeSessionInfo(sourceLabel: "Comet Default", token: "personal")
        let strictTeam = Self.makeSessionInfo(sourceLabel: "Comet Profile 1", token: "team")
        let duplicatePersonal = Self.makeSessionInfo(
            sourceLabel: "Comet Alternate Personal Label",
            token: "personal")
        let domainValid = Self.makeSessionInfo(
            sourceLabel: "Comet Profile 2 (domain cookies)",
            token: "domain")
        var importPhases: [String] = []
        let validatedHeaders = LockedArray<String>()
        let cacheOperations = KeychainCacheStore.OperationRecorder()

        let results = try await KeychainCacheStore.withOperationRecorderForTesting(cacheOperations) {
            try await probe.fetchBrowserLoginCandidates(
                browser: .comet,
                importSessions: { browser in
                    #expect(browser == .comet)
                    importPhases.append("strict")
                    return [strictPersonal, strictTeam]
                },
                importDomainSessions: { browser in
                    #expect(browser == .comet)
                    importPhases.append("domain")
                    return [duplicatePersonal, domainValid]
                },
                fetchSnapshot: { cookieHeader in
                    validatedHeaders.append(cookieHeader)
                    switch cookieHeader {
                    case strictPersonal.cookieHeader:
                        return Self.makeBrowserLoginSnapshot(
                            accountID: "personal-id",
                            email: "personal@example.com")
                    case strictTeam.cookieHeader:
                        return Self.makeBrowserLoginSnapshot(accountID: "team-id", email: "team@example.com")
                    case domainValid.cookieHeader:
                        return Self.makeBrowserLoginSnapshot(accountID: "domain-id", email: "domain@example.com")
                    default:
                        throw CursorStatusProbeError.parseFailed("unexpected test session")
                    }
                })
        }

        #expect(importPhases == ["strict", "domain"])
        #expect(results.map(\.sourceLabel) == [
            strictPersonal.sourceLabel,
            strictTeam.sourceLabel,
            domainValid.sourceLabel,
        ])
        #expect(results.map(\.snapshot.accountID) == ["personal-id", "team-id", "domain-id"])
        #expect(validatedHeaders.snapshot() == [
            strictPersonal.cookieHeader,
            strictTeam.cookieHeader,
            domainValid.cookieHeader,
        ])
        #expect(cacheOperations.operations.isEmpty)
    }

    @Test
    func `browser login candidates keep valid results when another profile has a transient failure`() async throws {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let valid = Self.makeSessionInfo(sourceLabel: "Comet Default", token: "valid")
        let transient = Self.makeSessionInfo(sourceLabel: "Comet Profile 1", token: "transient")
        let authRejected = Self.makeSessionInfo(sourceLabel: "Comet Profile 2", token: "auth-rejected")

        let results = try await probe.fetchBrowserLoginCandidates(
            browser: .comet,
            importSessions: { _ in [valid, transient] },
            importDomainSessions: { _ in [authRejected] },
            fetchSnapshot: { cookieHeader in
                switch cookieHeader {
                case valid.cookieHeader:
                    return Self.makeBrowserLoginSnapshot(accountID: "valid-id", email: "valid@example.com")
                case transient.cookieHeader:
                    throw CursorStatusProbeError.networkError("transient failure")
                case authRejected.cookieHeader:
                    throw CursorStatusProbeError.notLoggedIn
                default:
                    throw CursorStatusProbeError.parseFailed("unexpected test session")
                }
            })

        #expect(results.map(\.snapshot.accountID) == ["valid-id"])
    }

    @Test
    func `browser login candidates skip identity-less success when another profile is valid`() async throws {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let incomplete = Self.makeSessionInfo(sourceLabel: "Comet Default", token: "incomplete")
        let valid = Self.makeSessionInfo(sourceLabel: "Comet Profile 1", token: "valid")

        let results = try await probe.fetchBrowserLoginCandidates(
            browser: .comet,
            importSessions: { _ in [incomplete, valid] },
            importDomainSessions: { _ in [] },
            fetchSnapshot: { cookieHeader in
                switch cookieHeader {
                case incomplete.cookieHeader:
                    return Self.makeBrowserLoginSnapshot(accountID: "  ", email: "\n")
                case valid.cookieHeader:
                    return Self.makeBrowserLoginSnapshot(accountID: "valid-id", email: "valid@example.com")
                default:
                    throw CursorStatusProbeError.parseFailed("unexpected test session")
                }
            })

        #expect(results.map(\.snapshot.accountID) == ["valid-id"])
    }

    @Test
    func `browser login candidate deadline fails closed before validating later profiles`() async {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let first = Self.makeSessionInfo(sourceLabel: "Comet Default", token: "first")
        let second = Self.makeSessionInfo(sourceLabel: "Comet Profile 1", token: "second")
        let validatedHeaders = LockedArray<String>()

        do {
            _ = try await probe.fetchBrowserLoginCandidates(
                browser: .comet,
                importSessions: { _ in [first, second] },
                importDomainSessions: { _ in [] },
                fetchSnapshot: { cookieHeader in
                    validatedHeaders.append(cookieHeader)
                    try await Task.sleep(nanoseconds: 20_000_000)
                    return Self.makeBrowserLoginSnapshot(
                        accountID: "first-id",
                        email: "first@example.com")
                },
                deadline: Date().addingTimeInterval(0.01))
            Issue.record("Expected browser candidate validation to time out")
        } catch let error as CursorStatusProbeError {
            guard case let .networkError(message) = error else {
                Issue.record("Expected deadline network error, got \(error)")
                return
            }
            #expect(message.contains("Timed out"))
        } catch {
            Issue.record("Expected Cursor deadline error, got \(error)")
        }

        #expect(validatedHeaders.snapshot() == [first.cookieHeader])
    }

    @Test
    func `imported session scan continues after non auth failure until later success`() async {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let expected = CursorStatusSnapshot(
            planPercentUsed: 0.441025641025641,
            autoPercentUsed: 0.36,
            apiPercentUsed: 0.7111111111111111,
            planUsedUSD: 0.86,
            planLimitUSD: 20.0,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil)

        let result = await probe.scanImportedSessions([
            Self.makeSessionInfo(sourceLabel: "Chrome"),
            Self.makeSessionInfo(sourceLabel: "Safari"),
        ]) { session in
            switch session.sourceLabel {
            case "Chrome":
                .failed(.networkError("HTTP 500"))
            case "Safari":
                .succeeded(expected)
            default:
                .tryNextBrowser
            }
        }

        switch result {
        case let .succeeded(snapshot):
            #expect(snapshot.planPercentUsed == expected.planPercentUsed)
            #expect(snapshot.autoPercentUsed == expected.autoPercentUsed)
            #expect(snapshot.apiPercentUsed == expected.apiPercentUsed)
        case .exhausted:
            Issue.record("Expected scan to continue to the later successful browser session")
        }
    }

    @Test
    func `imported session scan preserves first non auth failure after exhausting sessions`() async {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))

        let result = await probe.scanImportedSessions([
            Self.makeSessionInfo(sourceLabel: "Chrome"),
            Self.makeSessionInfo(sourceLabel: "Safari"),
            Self.makeSessionInfo(sourceLabel: "Arc"),
        ]) { session in
            switch session.sourceLabel {
            case "Chrome":
                .failed(.networkError("HTTP 500"))
            case "Safari":
                .tryNextBrowser
            case "Arc":
                .failed(.parseFailed("bad payload"))
            default:
                .tryNextBrowser
            }
        }

        switch result {
        case .succeeded:
            Issue.record("Expected scan to report the first recoverable error after exhausting sessions")
        case let .exhausted(error):
            guard let error else {
                Issue.record("Expected first recoverable error to be preserved")
                return
            }
            guard case let .networkError(message) = error else {
                Issue.record("Expected first recoverable error to be the Chrome network failure")
                return
            }
            #expect(message == "HTTP 500")
        }
    }

    @Test
    func `browser scan stops importing after later browser succeeds`() async {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let expected = CursorStatusSnapshot(
            planPercentUsed: 42,
            autoPercentUsed: 12,
            apiPercentUsed: 85,
            planUsedUSD: 8.4,
            planLimitUSD: 20,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil)
        var importedLabels: [String] = []

        let result = await probe.scanBrowsers(
            [.chrome, .safari, .chromeBeta],
            importSessions: { browser in
                importedLabels.append(browser.displayName)
                switch browser {
                case .chrome:
                    return [Self.makeSessionInfo(sourceLabel: "Chrome")]
                case .safari:
                    return [Self.makeSessionInfo(sourceLabel: "Safari")]
                case .chromeBeta:
                    return [Self.makeSessionInfo(sourceLabel: "Chrome Beta")]
                default:
                    return []
                }
            },
            attemptFetch: { session in
                switch session.sourceLabel {
                case "Chrome":
                    .failed(.networkError("HTTP 500"))
                case "Safari":
                    .succeeded(expected)
                default:
                    .tryNextBrowser
                }
            })

        switch result {
        case let .succeeded(snapshot):
            #expect(snapshot.planPercentUsed == expected.planPercentUsed)
            #expect(importedLabels == ["Chrome", "Safari"])
        case .exhausted:
            Issue.record("Expected browser scan to stop after the later successful browser")
        }
    }

    @Test
    func `browser scan keeps trying later sources within the same browser`() async {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let expected = CursorStatusSnapshot(
            planPercentUsed: 12,
            autoPercentUsed: 3,
            apiPercentUsed: 45,
            planUsedUSD: 2.4,
            planLimitUSD: 20,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil)
        var attemptedSources: [String] = []

        let result = await probe.scanBrowsers(
            [.chrome, .safari],
            importSessions: { browser in
                switch browser {
                case .chrome:
                    [
                        Self.makeSessionInfo(sourceLabel: "Chrome Profile 1"),
                        Self.makeSessionInfo(sourceLabel: "Chrome Profile 2 (domain cookies)"),
                    ]
                case .safari:
                    [Self.makeSessionInfo(sourceLabel: "Safari")]
                default:
                    []
                }
            },
            attemptFetch: { session in
                attemptedSources.append(session.sourceLabel)
                switch session.sourceLabel {
                case "Chrome Profile 1":
                    return CursorStatusProbe.ImportedSessionFetchOutcome.failed(.networkError("HTTP 500"))
                case "Chrome Profile 2 (domain cookies)":
                    return CursorStatusProbe.ImportedSessionFetchOutcome.succeeded(expected)
                default:
                    return CursorStatusProbe.ImportedSessionFetchOutcome.tryNextBrowser
                }
            })

        switch result {
        case let .succeeded(snapshot):
            #expect(snapshot.planPercentUsed == expected.planPercentUsed)
            #expect(attemptedSources == ["Chrome Profile 1", "Chrome Profile 2 (domain cookies)"])
        case .exhausted:
            Issue.record("Expected browser scan to continue to later sources within the same browser")
        }
    }

    private static func makeSessionInfo(
        sourceLabel: String,
        token: String? = nil) -> CursorCookieImporter.SessionInfo
    {
        let cookieProps: [HTTPCookiePropertyKey: Any] = [
            .name: "WorkosCursorSessionToken",
            .value: token ?? sourceLabel.lowercased(),
            .domain: "cursor.com",
            .path: "/",
            .secure: true,
        ]

        let cookie = HTTPCookie(properties: cookieProps)!
        return CursorCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: sourceLabel)
    }

    private static func makeBrowserLoginSnapshot(
        accountID: String?,
        email: String?) -> CursorStatusSnapshot
    {
        CursorStatusSnapshot(
            planPercentUsed: 12,
            planUsedUSD: 1,
            planLimitUSD: 20,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: email,
            accountID: accountID,
            accountName: nil,
            rawJSON: nil)
    }
}
