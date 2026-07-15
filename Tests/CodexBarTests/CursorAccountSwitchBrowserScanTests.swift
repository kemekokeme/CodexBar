import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct CursorAccountSwitchBrowserScanTests {
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
    func `interactive browser mapping recognizes Comet and Chrome and rejects unknown apps`() {
        let comet = CursorStatusProbe.interactiveBrowser(bundleIdentifier: "ai.perplexity.comet")
        let chrome = CursorStatusProbe.interactiveBrowser(bundleIdentifier: "com.google.Chrome")
        let unknown = CursorStatusProbe.interactiveBrowser(bundleIdentifier: "com.example.unknown")
        let unverifiedArcChannel = CursorStatusProbe.interactiveBrowser(
            bundleIdentifier: "company.thebrowser.Browser.beta")
        let ambiguousYandexChannel = CursorStatusProbe.interactiveBrowser(
            bundleIdentifier: "ru.yandex.desktop.yandex-browser")

        #expect(comet == .comet)
        #expect(chrome == .chrome)
        #expect(unknown == nil)
        #expect(unverifiedArcChannel == nil)
        #expect(ambiguousYandexChannel == nil)
    }

    @Test
    func `interactive browser mapping covers every unambiguous SweetCookieKit browser`() {
        let mapping = CursorStatusProbe.interactiveBrowserByBundleIdentifier
        let mappedBrowsers = Set(mapping.values)
        let deliberatelyUnsupported: Set<Browser> = [.arcBeta, .arcCanary, .yandex]

        #expect(mapping.count == mappedBrowsers.count)
        #expect(mappedBrowsers.isDisjoint(with: deliberatelyUnsupported))
        #expect(mappedBrowsers.union(deliberatelyUnsupported) == Set(Browser.allCases))
        #expect(mapping.keys.allSatisfy { !$0.isEmpty && $0 == $0.lowercased() })
    }

    @Test
    func `interactive Comet candidate scan ignores valid Safari account and returns only Comet account`() async throws {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let safari = Self.makeSessionInfo(sourceLabel: "Safari Personal")
        let comet = Self.makeSessionInfo(sourceLabel: "Comet Work")
        let fixtures = [
            safari.cookieHeader: Self.snapshot(accountID: "personal-id", email: "personal@example.com"),
            comet.cookieHeader: Self.snapshot(accountID: "work-id", email: "work@example.com"),
        ]
        let importedBrowsers = LockedArray<String>()
        let attemptedHeaders = LockedArray<String>()

        let results = try await probe.fetchBrowserLoginCandidates(
            browser: .comet,
            importSessions: { candidate in
                importedBrowsers.append("strict:\(candidate.displayName)")
                return switch candidate {
                case .safari: [safari]
                case .comet: [comet]
                default: []
                }
            },
            importDomainSessions: { candidate in
                importedBrowsers.append("domain:\(candidate.displayName)")
                return []
            },
            fetchSnapshot: { cookieHeader in
                attemptedHeaders.append(cookieHeader)
                guard let snapshot = fixtures[cookieHeader] else {
                    throw URLError(.badServerResponse)
                }
                return snapshot
            })

        #expect(results.map(\.snapshot.accountID) == ["work-id"])
        #expect(results.map(\.sourceLabel) == ["Comet Work"])
        #expect(importedBrowsers.snapshot() == ["strict:Comet", "domain:Comet"])
        #expect(attemptedHeaders.snapshot() == [comet.cookieHeader])
    }

    @Test
    func `interactive Comet login with no session does not fall back to valid Safari account`() async throws {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let safari = Self.makeSessionInfo(sourceLabel: "Safari Personal")
        let importedBrowsers = LockedArray<String>()

        do {
            _ = try await probe.fetchBrowserLoginCandidates(
                browser: .comet,
                importSessions: { candidate in
                    importedBrowsers.append("strict:\(candidate.displayName)")
                    return candidate == .safari ? [safari] : []
                },
                importDomainSessions: { candidate in
                    importedBrowsers.append("domain:\(candidate.displayName)")
                    return candidate == .safari ? [safari] : []
                },
                fetchSnapshot: { _ in
                    Issue.record("No session should be attempted when Comet has no Cursor cookies")
                    throw CursorStatusProbeError.parseFailed("unexpected session")
                })
            Issue.record("Expected the Comet-only scan to remain unresolved")
        } catch let error as CursorStatusProbeError {
            guard case .noSessionCookie = error else {
                Issue.record("Expected no-session error, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected Cursor no-session error, got \(error)")
        }
        #expect(importedBrowsers.snapshot() == ["strict:Comet", "domain:Comet"])
    }

    @Test
    func `browser scan skips rejected old account and caches only accepted new account`() async {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let safari = Self.makeSessionInfo(sourceLabel: "Safari")
        let chrome = Self.makeSessionInfo(sourceLabel: "Chrome")
        let fixtures = [
            safari.cookieHeader: Self.snapshot(accountID: "old-id", email: "old@example.com"),
            chrome.cookieHeader: Self.snapshot(accountID: "new-id", email: "new@example.com"),
        ]
        let attemptedHeaders = LockedArray<String>()
        let cachedSources = LockedArray<String>()

        let result = await probe.scanBrowsers(
            [.safari, .chrome],
            importSessions: { browser in
                switch browser {
                case .safari: [safari]
                case .chrome: [chrome]
                default: []
                }
            },
            attemptFetch: { session in
                await probe.fetchIfSessionAccepted(
                    session,
                    log: { _ in },
                    acceptSnapshot: { $0.accountID == "new-id" },
                    fetchSnapshot: { cookieHeader in
                        attemptedHeaders.append(cookieHeader)
                        guard let snapshot = fixtures[cookieHeader] else {
                            throw URLError(.badServerResponse)
                        }
                        return snapshot
                    },
                    cacheAcceptedSession: { cachedSources.append($0.sourceLabel) })
            })

        switch result {
        case let .succeeded(snapshot):
            #expect(snapshot.accountID == "new-id")
        case .exhausted:
            Issue.record("Expected the later Chrome account to be accepted")
        }
        #expect(attemptedHeaders.snapshot() == [safari.cookieHeader, chrome.cookieHeader])
        #expect(cachedSources.snapshot() == ["Chrome"])
    }

    private static func makeSessionInfo(sourceLabel: String) -> CursorCookieImporter.SessionInfo {
        let cookieProps: [HTTPCookiePropertyKey: Any] = [
            .name: "WorkosCursorSessionToken",
            .value: sourceLabel.lowercased(),
            .domain: "cursor.com",
            .path: "/",
            .secure: true,
        ]

        let cookie = HTTPCookie(properties: cookieProps)!
        return CursorCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: sourceLabel)
    }

    private static func snapshot(accountID: String, email: String) -> CursorStatusSnapshot {
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
