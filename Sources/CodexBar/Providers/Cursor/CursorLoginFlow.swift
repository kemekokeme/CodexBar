import CodexBarCore

@MainActor
extension StatusItemController {
    func runCursorLoginFlow() async -> Bool {
        let currentIdentity = self.store.snapshot(for: .cursor)?.identity(for: .cursor)
        let priorAccount = currentIdentity.map {
            CursorLoginRunner.AccountIdentity(accountID: $0.accountID, email: $0.accountEmail)
        }

        // Stop older refreshes from publishing while the interactive login replaces the session.
        self.store.invalidateProviderRefreshRequests(.cursor)
        let cursorRunner = CursorLoginRunner(
            browserDetection: self.store.browserDetection,
            priorAccount: priorAccount,
            replaceSessionCache: { session in
                await CursorLoginRunner.replaceCachedSession(session) {
                    // Finalize without suspending: future refreshes use the chosen cached browser session,
                    // while any refresh that started during the interactive flow loses publication ownership.
                    self.settings.cursorCookieSource = .auto
                    self.store.invalidateProviderRefreshRequests(.cursor)
                }
            })
        let phaseHandler: @MainActor (CursorLoginRunner.Phase) -> Void = { [weak self] phase in
            switch phase {
            case .loading, .waitingLogin:
                self?.loginPhase = .waitingBrowser
            case .success, .failed:
                self?.loginPhase = .idle
            }
        }
        let result = await cursorRunner.run(onPhaseChange: phaseHandler)
        guard !Task.isCancelled else { return false }
        self.loginPhase = .idle
        self.presentCursorLoginResult(result)
        let outcome = self.describe(result.outcome)
        self.loginLogger.info("Cursor login", metadata: ["outcome": outcome])
        if case .success = result.outcome {
            self.postLoginNotification(for: .cursor)
            return true
        }
        return false
    }
}
