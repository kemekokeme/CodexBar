import Foundation
#if canImport(SweetCookieKit)
import SweetCookieKit
#endif

public enum KeychainAccessGate {
    private static let flagKey = "debugDisableKeychainAccess"
    static let disableAccessEnvironmentKey = "CODEXBAR_DISABLE_KEYCHAIN_ACCESS"
    @TaskLocal private static var taskOverrideValue: Bool?
    // `overrideValue`, `processForceDisabledReason`, and the mirrored
    // `BrowserCookieKeychainAccessGate.isDisabled` write are all guarded by `stateLock`.
    // It is recursive because the `isDisabled` setter and the process/reset helpers
    // recompute the mirror value through the `isDisabled` getter while already holding
    // the lock. Without a single lock, the setter and `resetOverrideForTesting` race on
    // these shared statics under parallel tests — and, in the app, a settings toggle
    // (`isDisabled` setter, main thread) can race a background-refresh read of the gate.
    private static let stateLock = NSRecursiveLock()
    private nonisolated(unsafe) static var overrideValue: Bool?
    private nonisolated(unsafe) static var processForceDisabledReason: String?

    public nonisolated(unsafe) static var isDisabled: Bool {
        get {
            if let taskOverrideValue { return taskOverrideValue }
            if self.isDisabledByEnvironment() { return true }
            #if DEBUG
            if Self.forcesDisabledUnderTests {
                return true
            }
            #endif
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            if self.processForceDisabledReason != nil { return true }
            if let overrideValue { return overrideValue }
            if UserDefaults.standard.bool(forKey: Self.flagKey) { return true }
            if let shared = AppGroupSupport.sharedDefaults(), shared.bool(forKey: Self.flagKey) {
                return true
            }
            return false
        }
        set {
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            overrideValue = newValue
            #if os(macOS) && canImport(SweetCookieKit)
            BrowserCookieKeychainAccessGate.isDisabled = self.isDisabled
            #endif
        }
    }

    static func isDisabledByEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        environment[self.disableAccessEnvironmentKey] == "1"
    }

    public static func forceDisabledForProcess(reason: String) {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.processForceDisabledReason = reason
        #if os(macOS) && canImport(SweetCookieKit)
        BrowserCookieKeychainAccessGate.isDisabled = self.isDisabled
        #endif
    }

    public static var processDisableReason: String? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.processForceDisabledReason
    }

    #if DEBUG
    private nonisolated(unsafe) static var forcesDisabledUnderTests: Bool {
        KeychainTestSafety.shouldBlockRealKeychainAccess()
    }
    #endif

    static func withTaskOverrideForTesting<T>(
        _ disabled: Bool?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskOverrideValue.withValue(disabled) {
            try operation()
        }
    }

    static func withTaskOverrideForTesting<T>(
        _ disabled: Bool?,
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskOverrideValue.withValue(disabled) {
            try await operation()
        }
    }

    static var currentOverrideForTesting: Bool? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.taskOverrideValue ?? self.overrideValue
    }

    #if DEBUG
    static func resetOverrideForTesting() {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.overrideValue = nil
        self.processForceDisabledReason = nil
        #if os(macOS) && canImport(SweetCookieKit)
        BrowserCookieKeychainAccessGate.isDisabled = self.isDisabled
        #endif
    }
    #endif
}
