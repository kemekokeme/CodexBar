import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized)
struct CLICookieRefreshTests {
    @Test
    func `cookie refresh parses explicit keychain acknowledgement`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(CookieOptions()))
        let parsed = try parser.parse(arguments: [
            "--provider", "opencodego", "--allow-keychain-prompt", "--json",
        ])

        #expect(parsed.options["provider"] == ["opencodego"])
        #expect(parsed.flags.contains("allowKeychainPrompt"))
        #expect(parsed.flags.contains("jsonShortcut"))
    }

    #if os(macOS)
    @Test
    func `all provider selection is descriptor driven`() throws {
        let targets = try CodexBarCLI.cookieRefreshTargets(rawProvider: nil, refreshAll: true)

        #expect(targets.count > 2)
        #expect(targets.contains(where: { $0.id == .claude }))
        #expect(targets.contains(where: { $0.id == .opencode }))
        #expect(targets.allSatisfy { $0.metadata.browserCookieOrder != nil })
        #expect(targets.allSatisfy { $0.fetchPlan.sourceModes.contains(.web) })
    }

    @Test
    func `prompt capable refresh is gated before provider work`() async {
        var operationCalled = false
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .opencode)

        let results = await CodexBarCLI.performCookieRefreshes(
            targets: [descriptor],
            allowKeychainPrompt: false)
        { _ in
            operationCalled = true
            return CookieRefreshResult(provider: "opencode", status: .refreshed, message: "unexpected")
        }

        #expect(operationCalled == false)
        #expect(results.count == 1)
        #expect(results[0].status == .blocked)
        #expect(results[0].message.contains("--allow-keychain-prompt"))
    }

    @Test
    func `preflight skip does not require keychain acknowledgement`() async {
        var operationCalled = false
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .opencode)

        let results = await CodexBarCLI.performCookieRefreshes(
            targets: [descriptor],
            allowKeychainPrompt: false,
            preflight: { descriptor in
                CookieRefreshResult(provider: descriptor.cli.name, status: .skipped, message: "manual")
            },
            operation: { _ in
                operationCalled = true
                return CookieRefreshResult(provider: "opencode", status: .refreshed, message: "unexpected")
            })

        #expect(operationCalled == false)
        #expect(results.count == 1)
        #expect(results[0].status == .skipped)
    }

    @Test
    func `explicit acknowledgement is user initiated and is the only cooldown bypass`() async {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        let start = Date(timeIntervalSince1970: 2000)
        BrowserCookieAccessGate.recordDenied(for: .chrome, now: start)
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .opencode)
        var unacknowledgedOperationCalled = false

        var observedInteraction: ProviderInteraction?
        var explicitRetryAllowed = false
        await KeychainAccessGate.withTaskOverrideForTesting(false) {
            _ = await CodexBarCLI.performCookieRefreshes(
                targets: [descriptor],
                allowKeychainPrompt: false)
            { _ in
                unacknowledgedOperationCalled = true
                return CookieRefreshResult(provider: "opencode", status: .refreshed, message: "unexpected")
            }

            _ = await CodexBarCLI.performCookieRefreshes(
                targets: [descriptor],
                allowKeychainPrompt: true)
            { _ in
                observedInteraction = ProviderInteractionContext.current
                explicitRetryAllowed = BrowserCookieAccessGate.shouldAttempt(
                    .chrome,
                    now: start.addingTimeInterval(1))
                return CookieRefreshResult(provider: "opencode", status: .refreshed, message: "ok")
            }
        }

        #expect(unacknowledgedOperationCalled == false)
        #expect(observedInteraction == .userInitiated)
        #expect(explicitRetryAllowed)
    }

    @Test
    func `raw provider failures cannot leak cookie values`() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            let privateMarker = "opaque-test-marker"
            let error = NSError(
                domain: privateMarker,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: privateMarker])

            let result = CodexBarCLI.cookieRefreshFailure(provider: .opencode, error: error)
            let text = CodexBarCLI.cookieRefreshText([result])
            let encoded = try? JSONEncoder().encode(result)
            let json = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""

            #expect(!text.contains(privateMarker))
            #expect(!json.contains(privateMarker))
            #expect(text.contains("six-hour denial cooldown"))
        }
    }

    @Test
    func `keychain failure reuses actionable denial hint`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        BrowserCookieAccessGate.recordDenied(for: .chrome)

        KeychainAccessGate.withTaskOverrideForTesting(false) {
            let result = CodexBarCLI.cookieRefreshFailure(
                provider: .opencode,
                error: NSError(domain: "opaque-test-marker", code: 1))

            #expect(result.message ==
                "Chrome cookie decryption was declined in Keychain; retry with --allow-keychain-prompt.")
            #expect(!result.message.contains("opaque-test-marker"))
        }
    }
    #endif
}
