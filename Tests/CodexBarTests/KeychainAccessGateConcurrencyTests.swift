import Foundation
import Testing
@testable import CodexBarCore

/// Regression test for the data race on `KeychainAccessGate`'s override statics and the
/// mirrored `BrowserCookieKeychainAccessGate.isDisabled` write. Before the fix, the
/// `isDisabled` setter and `resetOverrideForTesting` wrote these shared statics with no
/// synchronization, so hammering them from concurrent threads is a data race that
/// `swift test --sanitize=thread` reports deterministically (it was flaky in the normal
/// suite because real tests only occasionally overlap). With the lock the accesses are
/// serialized. ThreadSanitizer is the oracle here — there is no value to `#expect`; the
/// pass condition is simply that no data race is reported while the lanes run.
@Suite(.serialized)
struct KeychainAccessGateConcurrencyTests {
    @Test
    func `concurrent override writes, resets, and reads are race-free`() {
        let iterations = 5000
        let lanes = 4
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "keychain-access-gate.concurrency", attributes: .concurrent)
        for lane in 0..<lanes {
            group.enter()
            queue.async {
                for i in 0..<iterations {
                    switch (lane + i) % 3 {
                    case 0: KeychainAccessGate.isDisabled = (i % 2 == 0)
                    case 1: KeychainAccessGate.resetOverrideForTesting()
                    default: _ = KeychainAccessGate.isDisabled
                    }
                }
                group.leave()
            }
        }
        group.wait()
        KeychainAccessGate.resetOverrideForTesting()
    }
}
