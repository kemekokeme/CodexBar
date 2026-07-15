import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CursorLoginRunnerTests {
    private static let cometApplicationURL = URL(fileURLWithPath: "/Applications/Comet.app")

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

    private final class SnapshotSequence: @unchecked Sendable {
        private let lock = NSLock()
        private let snapshots: [CursorStatusSnapshot]
        private var index = 0

        init(_ snapshots: [CursorStatusSnapshot]) {
            self.snapshots = snapshots
        }

        func next() -> CursorStatusSnapshot {
            self.lock.lock()
            defer { self.lock.unlock() }
            let snapshot = self.snapshots[min(self.index, self.snapshots.count - 1)]
            self.index += 1
            return snapshot
        }

        func count() -> Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.index
        }
    }

    @Test
    func `add account opens Cursor auth URL in browser before polling cookies`() async {
        var launchedRoutes: [CursorLoginBrowserRouter.Route] = []
        var resolvedURLs: [URL] = []
        var phases: [String] = []

        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.01,
            launchRoute: { route in
                launchedRoutes.append(route)
                return true
            },
            loadSnapshot: { Self.snapshot(email: "cursor@example.com") },
            sleeper: { _ in },
            browserApplicationResolver: {
                resolvedURLs.append($0)
                return Self.cometApplicationURL
            },
            routeResolver: Self.fixtureRouteResolver,
            resetSessionCache: {})

        #expect(resolvedURLs.isEmpty)

        let result = await runner.run { phase in
            switch phase {
            case .loading: phases.append("loading")
            case .waitingLogin: phases.append("waitingLogin")
            case .success: phases.append("success")
            case let .failed(message): phases.append("failed:\(message)")
            }
        }

        #expect(launchedRoutes.map(\.launchURL) == [CursorLoginRunner.authURL])
        #expect(launchedRoutes.map(\.browserApplicationURL) == [Self.cometApplicationURL])
        #expect(resolvedURLs == [CursorLoginRunner.authURL])
        #expect(phases == ["loading", "waitingLogin", "success"])
        #expect(result.email == "cursor@example.com")
    }

    @Test
    func `add account ignores identity-less snapshots`() async {
        let sequence = SnapshotSequence([
            Self.snapshot(email: nil),
            Self.snapshot(email: "cursor@example.com"),
        ])
        let runner = Self.runner(loadSnapshot: { sequence.next() })

        let result = await runner.run { _ in }

        #expect(sequence.count() == 2)
        #expect(result.email == "cursor@example.com")
    }

    @Test
    func `switch account opens mismatch route and waits for a different normalized email`() async {
        var launchedRoutes: [CursorLoginBrowserRouter.Route] = []
        var resolvedURLs: [URL] = []
        let sequence = SnapshotSequence([
            Self.snapshot(email: "  CURRENT@example.com "),
            Self.snapshot(email: nil),
            Self.snapshot(email: "different@example.com"),
        ])
        let runner = Self.runner(
            priorAccount: .init(email: "current@example.com"),
            launchRoute: {
                launchedRoutes.append($0)
                return true
            },
            browserApplicationResolver: {
                resolvedURLs.append($0)
                return Self.cometApplicationURL
            },
            loadSnapshot: { sequence.next() })

        let result = await runner.run { _ in }

        #expect(launchedRoutes.map(\.launchURL) == [CursorLoginRunner.switchAccountURL])
        #expect(launchedRoutes.map(\.browserApplicationURL) == [Self.cometApplicationURL])
        #expect(resolvedURLs == [CursorLoginRunner.switchAccountURL])
        #expect(sequence.count() == 3)
        #expect(result.email == "different@example.com")
    }

    @Test
    func `switch timeout explains that a different account is required`() async {
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            priorAccount: .init(email: "current@example.com"),
            timeout: 0,
            pollInterval: 0.01,
            launchRoute: { _ in true },
            loadSnapshot: { Self.snapshot(email: "current@example.com") },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            resetSessionCache: {})

        let result = await runner.run { _ in }

        guard case let .failed(message) = result.outcome else {
            Issue.record("Expected failed outcome")
            return
        }
        #expect(message.contains("different Cursor account"))
    }

    @Test
    func `login clears stale session state before opening auth URL`() async {
        let events = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.01,
            launchRoute: { _ in
                events.append("open")
                return true
            },
            loadSnapshot: {
                events.append("poll")
                return Self.snapshot(email: "cursor@example.com")
            },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            resetSessionCache: {
                events.append("reset")
            })

        _ = await runner.run { _ in }

        #expect(Array(events.snapshot().prefix(3)) == ["reset", "open", "poll"])
    }

    @Test
    func `login reports launch failure when browser cannot open`() async {
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            launchRoute: { _ in false },
            loadSnapshot: {
                Issue.record("Should not poll cookies when browser launch fails")
                throw CursorStatusProbeError.noSessionCookie
            },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            resetSessionCache: {})

        let result = await runner.run { _ in }

        guard case let .failed(message) = result.outcome else {
            Issue.record("Expected failed outcome")
            return
        }
        #expect(message.contains("Could not open Cursor login"))
    }

    @Test
    func `unsupported default browser fails before opening or polling`() async {
        var launchedRoutes: [CursorLoginBrowserRouter.Route] = []
        let pollEvents = LockedArray<String>()
        let resetEvents = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            launchRoute: {
                launchedRoutes.append($0)
                return true
            },
            loadSnapshot: {
                pollEvents.append("poll")
                return Self.snapshot(email: "wrong@example.com")
            },
            sleeper: { _ in },
            browserApplicationResolver: { _ in
                URL(fileURLWithPath: "/Applications/Unsupported Browser.app")
            },
            routeResolver: { _, _ in .unavailable },
            resetSessionCache: { resetEvents.append("reset") })

        let result = await runner.run { _ in }

        guard case let .failed(message) = result.outcome else {
            Issue.record("Expected unsupported-browser failure")
            return
        }
        #expect(message.contains("Unsupported Browser"))
        #expect(message.contains("Cookie header"))
        #expect(launchedRoutes.isEmpty)
        #expect(pollEvents.snapshot().isEmpty)
        #expect(resetEvents.snapshot().isEmpty)
    }

    @Test
    func `unresolved default browser fails before opening or polling`() async {
        var launchedRoutes: [CursorLoginBrowserRouter.Route] = []
        let pollEvents = LockedArray<String>()
        let resetEvents = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            launchRoute: {
                launchedRoutes.append($0)
                return true
            },
            loadSnapshot: {
                pollEvents.append("poll")
                return Self.snapshot(email: "wrong@example.com")
            },
            sleeper: { _ in },
            browserApplicationResolver: { _ in nil },
            routeResolver: { _, _ in .unavailable },
            resetSessionCache: { resetEvents.append("reset") })

        let result = await runner.run { _ in }

        guard case let .failed(message) = result.outcome else {
            Issue.record("Expected unresolved-browser failure")
            return
        }
        #expect(message.contains("Browser cookies"))
        #expect(message.contains("Cookie header"))
        #expect(launchedRoutes.isEmpty)
        #expect(pollEvents.snapshot().isEmpty)
        #expect(resetEvents.snapshot().isEmpty)
    }

    @Test
    func `browser chooser cancellation happens before reset launch and polling`() async {
        let events = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            launchRoute: { _ in
                events.append("launch")
                return true
            },
            loadSnapshot: {
                events.append("poll")
                return Self.snapshot(email: "unexpected@example.com")
            },
            browserApplicationResolver: { _ in
                URL(fileURLWithPath: "/Applications/Link Router.app")
            },
            routeResolver: { _, _ in .cancelled },
            resetSessionCache: { events.append("reset") })

        let result = await runner.run { _ in }

        guard case .cancelled = result.outcome else {
            Issue.record("Expected browser selection cancellation")
            return
        }
        #expect(events.snapshot().isEmpty)
    }

    @Test
    func `production candidate loader receives the exact pinned browser URL`() async {
        let loadedBrowserURLs = LockedArray<URL>()
        let candidateTimeouts = LockedArray<TimeInterval>()
        var launchedRoutes: [CursorLoginBrowserRouter.Route] = []
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: {
                launchedRoutes.append($0)
                return true
            },
            loadBrowserLoginCandidates: { browserApplicationURL, timeout in
                loadedBrowserURLs.append(browserApplicationURL)
                candidateTimeouts.append(timeout)
                return [Self.browserCandidate(
                    id: "account",
                    email: "cursor@example.com",
                    token: "token",
                    source: "Comet")]
            },
            sleeper: { _ in },
            browserApplicationResolver: { _ in
                URL(fileURLWithPath: "/Applications/Link Router.app")
            },
            routeResolver: { _, _ in
                .route(.init(
                    launchURL: URL(string: "https://example.invalid/intermediary")!,
                    browserApplicationURL: Self.cometApplicationURL))
            },
            resetSessionCache: {})

        _ = await runner.run { _ in }

        #expect(launchedRoutes.map(\.launchURL) == [CursorLoginRunner.authURL])
        #expect(launchedRoutes.map(\.browserApplicationURL) == [Self.cometApplicationURL])
        #expect(loadedBrowserURLs.snapshot() == [Self.cometApplicationURL])
        let passedTimeout = candidateTimeouts.snapshot().first
        #expect(passedTimeout.map { $0 > 0 && $0 <= 1 } == true)
    }

    @Test
    func `account chooser cancel and forged result commit no session`() async {
        for chosenID in [String?.none, "forged-selection"] {
            let committedHeaders = LockedArray<String>()
            var presentedChoices: [CursorLoginAccountSelector.Choice] = []
            let runner = CursorLoginRunner(
                browserDetection: BrowserDetection(cacheTTL: 0),
                timeout: 1,
                pollInterval: 0.001,
                launchRoute: { _ in true },
                loadBrowserLoginCandidates: { _, _ in [
                    Self.browserCandidate(id: "account-a", email: "a@example.com", token: "token-a", source: "Work"),
                    Self.browserCandidate(
                        id: "account-b",
                        email: "b@example.com",
                        token: "token-b",
                        source: "Personal"),
                ] },
                sleeper: { _ in },
                browserApplicationResolver: { _ in Self.cometApplicationURL },
                routeResolver: Self.fixtureRouteResolver,
                accountChooser: { choices in
                    presentedChoices = choices
                    return chosenID
                },
                resetSessionCache: {},
                commitSessionCache: { session in
                    committedHeaders.append(session.cookieHeader)
                })

            let result = await runner.run { _ in }

            guard case .cancelled = result.outcome else {
                Issue.record("Expected account selection cancellation")
                continue
            }
            #expect(presentedChoices.count == 2)
            #expect(Set(presentedChoices.map(\.selectionID)) == [
                "cursor-candidate-0",
                "cursor-candidate-1",
            ])
            #expect(committedHeaders.snapshot().isEmpty)
        }
    }

    @Test
    func `account candidates dedupe by stable ID and preserve distinct IDs with the same email`() async {
        var presentedChoices: [CursorLoginAccountSelector.Choice] = []
        let committedHeaders = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: { _ in true },
            loadBrowserLoginCandidates: { _, _ in [
                Self.browserCandidate(
                    id: " account-a ",
                    email: "same@example.com",
                    token: "first-a",
                    source: "Work"),
                Self.browserCandidate(
                    id: "account-a",
                    email: "other@example.com",
                    token: "duplicate-a",
                    source: "Work Network"),
                Self.browserCandidate(
                    id: "account-b",
                    email: "same@example.com",
                    token: "token-b",
                    source: "Personal"),
            ] },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            accountChooser: { choices in
                presentedChoices = choices
                return choices.first(where: { $0.displayLabel.contains("Personal") })?.selectionID
            },
            resetSessionCache: {},
            commitSessionCache: { session in
                committedHeaders.append(session.cookieHeader)
            })

        _ = await runner.run { _ in }

        #expect(presentedChoices.count == 2)
        #expect(committedHeaders.snapshot() == ["WorkosCursorSessionToken=token-b"])
    }

    @Test
    func `account candidates use normalized email only when stable ID is absent`() async {
        var chooserCalls = 0
        let committedHeaders = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: { _ in true },
            loadBrowserLoginCandidates: { _, _ in [
                Self.browserCandidate(id: nil, email: " SAME@example.com ", token: "first", source: "Work"),
                Self.browserCandidate(id: nil, email: "same@example.com", token: "second", source: "Personal"),
            ] },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            accountChooser: { _ in
                chooserCalls += 1
                return nil
            },
            resetSessionCache: {},
            commitSessionCache: { session in
                committedHeaders.append(session.cookieHeader)
            })

        _ = await runner.run { _ in }

        #expect(chooserCalls == 0)
        #expect(committedHeaders.snapshot() == ["WorkosCursorSessionToken=first"])
    }

    @Test
    func `identified candidate replaces an earlier email only candidate`() async {
        var chooserCalls = 0
        let committedHeaders = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: { _ in true },
            loadBrowserLoginCandidates: { _, _ in [
                Self.browserCandidate(
                    id: nil,
                    email: "same@example.com",
                    token: "email-only",
                    source: "Work"),
                Self.browserCandidate(
                    id: "stable-account",
                    email: " SAME@example.com ",
                    token: "identified",
                    source: "Personal"),
            ] },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            accountChooser: { _ in
                chooserCalls += 1
                return nil
            },
            resetSessionCache: {},
            commitSessionCache: { session in
                committedHeaders.append(session.cookieHeader)
            })

        _ = await runner.run { _ in }

        #expect(chooserCalls == 0)
        #expect(committedHeaders.snapshot() == ["WorkosCursorSessionToken=identified"])
    }

    private static func runner(
        priorAccount: CursorLoginRunner.AccountIdentity? = nil,
        launchRoute: @escaping CursorLoginRunner.RouteLauncher = { _ in true },
        browserApplicationResolver: @escaping CursorLoginRunner.BrowserApplicationResolver = { _ in
            Self.cometApplicationURL
        },
        loadSnapshot: @escaping CursorLoginRunner.SnapshotLoader) -> CursorLoginRunner
    {
        CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            priorAccount: priorAccount,
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: launchRoute,
            loadSnapshot: loadSnapshot,
            sleeper: { _ in },
            browserApplicationResolver: browserApplicationResolver,
            routeResolver: self.fixtureRouteResolver,
            resetSessionCache: {})
    }

    private static func fixtureRouteResolver(
        loginURL: URL,
        handlerApplicationURL: URL?) -> CursorLoginBrowserRouter.Resolution
    {
        guard let handlerApplicationURL else { return .unavailable }
        return .route(.init(
            launchURL: loginURL,
            browserApplicationURL: handlerApplicationURL))
    }

    private nonisolated static func snapshot(id: String? = nil, email: String?) -> CursorStatusSnapshot {
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
            accountID: id,
            accountName: nil,
            rawJSON: nil)
    }

    private nonisolated static func browserCandidate(
        id: String?,
        email: String?,
        token: String,
        source: String) -> CursorStatusProbe.BrowserLoginResult
    {
        CursorStatusProbe.BrowserLoginResult(
            snapshot: self.snapshot(id: id, email: email),
            session: .init(
                cookieHeader: "WorkosCursorSessionToken=\(token)",
                sourceLabel: source))
    }
}
