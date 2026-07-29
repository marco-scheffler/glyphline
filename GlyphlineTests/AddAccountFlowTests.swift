import XCTest
@testable import Glyphline

/// The rules that decide what the Add Account screen actually writes.
///
/// Every test here runs with a fake sign-in presenter. Nothing in this file may
/// ever put a window on screen or touch `WKWebView`: the seam exists precisely so
/// the decisions around the window can be pinned without one.
@MainActor
final class AddAccountFlowTests: XCTestCase {
    // MARK: - Doubles

    @MainActor
    private final class FakeSignIn: ClaudeSignInPresenting {
        var outcome: ClaudeSignInWindow.Outcome
        private(set) var presentedAccounts: [Account] = []

        init(outcome: ClaudeSignInWindow.Outcome) {
            self.outcome = outcome
        }

        func presentSignIn(for account: Account) async -> ClaudeSignInWindow.Outcome {
            presentedAccounts.append(account)
            return outcome
        }
    }

    /// A stand-in for WebKit. Nothing here may touch a real `WKWebsiteDataStore`:
    /// removing one is a process-wide call against a directory in the developer's
    /// own Library.
    @MainActor
    private final class RecordingRemover: WebSessionRemoving {
        private(set) var removed: [UUID] = []

        func removeSession(for accountID: UUID) async throws {
            removed.append(accountID)
        }
    }

    private final class RecordingCredentialStore: CredentialStore, @unchecked Sendable {
        private(set) var saved: [String: String] = [:]
        private(set) var deleted: [String] = []

        func save(secret: String, for reference: String) throws {
            saved[reference] = secret
        }

        func readSecret(for reference: String) throws -> String? {
            saved[reference]
        }

        func deleteSecret(for reference: String) throws {
            deleted.append(reference)
            saved.removeValue(forKey: reference)
        }
    }

    // MARK: - Fixtures

    private func makeLedger() throws -> LedgerStore {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        return LedgerStore(dbQueue: dbQueue)
    }

    /// A ledger whose tables were never created, so `saveAccount` throws. The one
    /// way to reach the save-failure exit without a stand-in for `LedgerStore`,
    /// which is a concrete type the flow holds directly.
    private func makeUnwritableLedger() throws -> LedgerStore {
        LedgerStore(dbQueue: try DatabaseQueueFactory.makeInMemory())
    }

    private func makeFlow(
        ledger: LedgerStore,
        credentials: RecordingCredentialStore,
        signIn: FakeSignIn,
        webSessions: RecordingRemover = RecordingRemover()
    ) -> AddAccountFlow {
        AddAccountFlow(
            ledgerStore: ledger,
            credentialStore: credentials,
            signIn: signIn,
            webSessions: webSessions
        )
    }

    private let organizationID = "11111111-1111-1111-1111-111111111111"

    // MARK: - Web session

    /// The whole point of the screen: a web-session account reaches the ledger
    /// with the organisation its sign-in resolved. Without that id the registry
    /// resolves no quota source at all and the account renders grey forever.
    func testAWebSessionAccountIsWrittenWithTheOrganisationItSignedInTo() async throws {
        let ledger = try makeLedger()
        let credentials = RecordingCredentialStore()
        let signIn = FakeSignIn(outcome: .signedIn(organizationID: organizationID))
        let flow = makeFlow(ledger: ledger, credentials: credentials, signIn: signIn)

        let outcome = await flow.save(
            providerID: .claude,
            displayName: "  Max #1  ",
            source: .claudeWebSession,
            credentialValue: "",
            isEnabled: true
        )

        XCTAssertEqual(outcome, .saved)

        let accounts = try ledger.fetchAccounts()
        XCTAssertEqual(accounts.count, 1)
        let account = try XCTUnwrap(accounts.first)
        XCTAssertEqual(account.claudeOrganizationID, organizationID)
        XCTAssertEqual(account.displayName, "Max #1")
        XCTAssertEqual(account.providerID, .claude)
        XCTAssertTrue(account.isEnabled)
    }

    /// The credential reference decides which adapter the cost path builds. A
    /// web-session account must carry its own scheme: `local-source://` would make
    /// every one of them read `~/.claude/projects`, so three subscriptions would
    /// report the same local logs three times over.
    func testAWebSessionAccountCarriesTheWebSessionSchemeAndNoSecret() async throws {
        let ledger = try makeLedger()
        let credentials = RecordingCredentialStore()
        let signIn = FakeSignIn(outcome: .signedIn(organizationID: organizationID))
        let flow = makeFlow(ledger: ledger, credentials: credentials, signIn: signIn)

        _ = await flow.save(
            providerID: .claude,
            displayName: "Max #1",
            source: .claudeWebSession,
            credentialValue: "",
            isEnabled: true
        )

        let account = try XCTUnwrap(try ledger.fetchAccounts().first)
        XCTAssertEqual(
            account.credentialReference,
            AccountCredentialReference.make(accountID: account.id, source: .claudeWebSession)
        )
        XCTAssertTrue(account.credentialReference.hasPrefix(ProviderAdapterRegistry.webSessionScheme))
        XCTAssertFalse(account.credentialReference.hasPrefix(ProviderAdapterRegistry.localSourceScheme))

        // There is no secret for this source, so nothing may be written — least of
        // all an empty string standing in for one.
        XCTAssertTrue(credentials.saved.isEmpty)
    }

    /// The session WebKit just established is keyed on the account id. If the
    /// account that gets persisted were a different one, its data store would be
    /// empty and the user would be asked to sign in again on the very next tick.
    func testTheSessionIsEstablishedForTheAccountThatGetsPersisted() async throws {
        let ledger = try makeLedger()
        let credentials = RecordingCredentialStore()
        let signIn = FakeSignIn(outcome: .signedIn(organizationID: organizationID))
        let flow = makeFlow(ledger: ledger, credentials: credentials, signIn: signIn)

        _ = await flow.save(
            providerID: .claude,
            displayName: "Max #1",
            source: .claudeWebSession,
            credentialValue: "",
            isEnabled: true
        )

        let persisted = try XCTUnwrap(try ledger.fetchAccounts().first)
        XCTAssertEqual(signIn.presentedAccounts.map(\.id), [persisted.id])
    }

    /// Closing the window is not a save. Nothing may be left behind, and the user
    /// has to be told that nothing was.
    func testCancellingSignInWritesNothing() async throws {
        let ledger = try makeLedger()
        let credentials = RecordingCredentialStore()
        let signIn = FakeSignIn(outcome: .cancelled)
        let flow = makeFlow(ledger: ledger, credentials: credentials, signIn: signIn)

        let outcome = await flow.save(
            providerID: .claude,
            displayName: "Max #1",
            source: .claudeWebSession,
            credentialValue: "",
            isEnabled: true
        )

        XCTAssertEqual(outcome, .failed(AddAccountFlow.signInCancelledMessage))
        XCTAssertTrue(try ledger.fetchAccounts().isEmpty)
        XCTAssertTrue(credentials.saved.isEmpty)
    }

    /// A failed sign-in is reported with the error's own message. The window has
    /// already worked out which failure it was; restating it here would be a second
    /// place for the wording to drift.
    func testAFailedSignInWritesNothingAndReportsTheErrorsOwnMessage() async throws {
        for error in [RateWindowSourceError.sessionExpired, .notAvailable, .transportFailure] {
            let ledger = try makeLedger()
            let credentials = RecordingCredentialStore()
            let signIn = FakeSignIn(outcome: .failed(error))
            let flow = makeFlow(ledger: ledger, credentials: credentials, signIn: signIn)

            let outcome = await flow.save(
                providerID: .claude,
                displayName: "Max #1",
                source: .claudeWebSession,
                credentialValue: "",
                isEnabled: true
            )

            XCTAssertEqual(outcome, .failed(error.message), "\(error)")
            XCTAssertTrue(try ledger.fetchAccounts().isEmpty, "\(error)")
            XCTAssertTrue(credentials.saved.isEmpty, "\(error)")
        }
    }

    /// An empty organisation id is not an organisation: `ClaudeWebEndpoints.usage`
    /// rejects it and the registry resolves no source for it. Writing the account
    /// anyway would produce exactly the useless grey row this flow exists to avoid.
    func testASignedInOutcomeWithoutAnOrganisationIsNotPersisted() async throws {
        let ledger = try makeLedger()
        let credentials = RecordingCredentialStore()
        let signIn = FakeSignIn(outcome: .signedIn(organizationID: ""))
        let flow = makeFlow(ledger: ledger, credentials: credentials, signIn: signIn)

        let outcome = await flow.save(
            providerID: .claude,
            displayName: "Max #1",
            source: .claudeWebSession,
            credentialValue: "",
            isEnabled: true
        )

        XCTAssertEqual(outcome, .failed(RateWindowSourceError.notAvailable.message))
        XCTAssertTrue(try ledger.fetchAccounts().isEmpty)
    }

    // MARK: - The session the window leaves behind

    // The sign-in window navigates to claude.ai the moment it opens, so WebKit has
    // written a persistent data store — keyed on this account id — before any of
    // these exits is reached. No row is written on any of them, and the store
    // identifier is derived from the id, so a store left behind here can never be
    // enumerated or named again. Each exit therefore has to remove it.

    func testCancellingSignInRemovesTheSessionItsWindowCreated() async throws {
        let webSessions = RecordingRemover()
        let signIn = FakeSignIn(outcome: .cancelled)
        let flow = makeFlow(
            ledger: try makeLedger(),
            credentials: RecordingCredentialStore(),
            signIn: signIn,
            webSessions: webSessions
        )

        _ = await flow.save(
            providerID: .claude,
            displayName: "Max #1",
            source: .claudeWebSession,
            credentialValue: "",
            isEnabled: true
        )

        let presented = try XCTUnwrap(signIn.presentedAccounts.first)
        XCTAssertEqual(webSessions.removed, [presented.id])
    }

    /// The worst shape of the orphan: the sign-in *worked*, so the store on disk
    /// holds a live claude.ai session. Verification then reported no quota, no
    /// account is written, and without this the session would sit there forever.
    func testAFailedSignInRemovesTheSessionItsWindowCreated() async throws {
        for error in [RateWindowSourceError.sessionExpired, .notAvailable, .transportFailure] {
            let webSessions = RecordingRemover()
            let signIn = FakeSignIn(outcome: .failed(error))
            let flow = makeFlow(
                ledger: try makeLedger(),
                credentials: RecordingCredentialStore(),
                signIn: signIn,
                webSessions: webSessions
            )

            _ = await flow.save(
                providerID: .claude,
                displayName: "Max #1",
                source: .claudeWebSession,
                credentialValue: "",
                isEnabled: true
            )

            let presented = try XCTUnwrap(signIn.presentedAccounts.first, "\(error)")
            XCTAssertEqual(webSessions.removed, [presented.id], "\(error)")
        }
    }

    func testASignedInOutcomeWithoutAnOrganisationRemovesTheSession() async throws {
        let webSessions = RecordingRemover()
        let signIn = FakeSignIn(outcome: .signedIn(organizationID: ""))
        let flow = makeFlow(
            ledger: try makeLedger(),
            credentials: RecordingCredentialStore(),
            signIn: signIn,
            webSessions: webSessions
        )

        _ = await flow.save(
            providerID: .claude,
            displayName: "Max #1",
            source: .claudeWebSession,
            credentialValue: "",
            isEnabled: true
        )

        let presented = try XCTUnwrap(signIn.presentedAccounts.first)
        XCTAssertEqual(webSessions.removed, [presented.id])
    }

    /// The exit that is easiest to forget: the sign-in succeeded and the write did
    /// not. There is still no row, so the id that names the store is still lost.
    func testAFailedSaveRemovesTheSessionTheSignInEstablished() async throws {
        let webSessions = RecordingRemover()
        let signIn = FakeSignIn(outcome: .signedIn(organizationID: organizationID))
        let flow = makeFlow(
            ledger: try makeUnwritableLedger(),
            credentials: RecordingCredentialStore(),
            signIn: signIn,
            webSessions: webSessions
        )

        let outcome = await flow.save(
            providerID: .claude,
            displayName: "Max #1",
            source: .claudeWebSession,
            credentialValue: "",
            isEnabled: true
        )

        XCTAssertEqual(outcome, .failed(AddAccountFlow.saveFailedMessage))
        let presented = try XCTUnwrap(signIn.presentedAccounts.first)
        XCTAssertEqual(webSessions.removed, [presented.id])
    }

    /// The other half of the rule. A saved account owns its session, and removing
    /// it here would sign the user straight back out of the account they just added.
    func testASavedAccountKeepsTheSessionItJustSignedInTo() async throws {
        let webSessions = RecordingRemover()
        let flow = makeFlow(
            ledger: try makeLedger(),
            credentials: RecordingCredentialStore(),
            signIn: FakeSignIn(outcome: .signedIn(organizationID: organizationID)),
            webSessions: webSessions
        )

        let outcome = await flow.save(
            providerID: .claude,
            displayName: "Max #1",
            source: .claudeWebSession,
            credentialValue: "",
            isEnabled: true
        )

        XCTAssertEqual(outcome, .saved)
        XCTAssertTrue(webSessions.removed.isEmpty)
    }

    /// Only a web session has a store to remove. A credential account whose write
    /// fails must not send WebKit after a data store that was never created.
    func testAFailedSaveOnACredentialAccountRemovesNoSession() async throws {
        let webSessions = RecordingRemover()
        let flow = makeFlow(
            ledger: try makeUnwritableLedger(),
            credentials: RecordingCredentialStore(),
            signIn: FakeSignIn(outcome: .signedIn(organizationID: organizationID)),
            webSessions: webSessions
        )

        let outcome = await flow.save(
            providerID: .claude,
            displayName: "Admin",
            source: .credential,
            credentialValue: "sk-ant-admin-secret",
            isEnabled: true
        )

        XCTAssertEqual(outcome, .failed(AddAccountFlow.saveFailedMessage))
        XCTAssertTrue(webSessions.removed.isEmpty)
    }

    // MARK: - The two sources that already existed

    func testACredentialAccountStoresItsSecretAndNeverPresentsSignIn() async throws {
        let ledger = try makeLedger()
        let credentials = RecordingCredentialStore()
        let signIn = FakeSignIn(outcome: .signedIn(organizationID: organizationID))
        let flow = makeFlow(ledger: ledger, credentials: credentials, signIn: signIn)

        let outcome = await flow.save(
            providerID: .claude,
            displayName: "Admin",
            source: .credential,
            credentialValue: "sk-ant-admin-secret",
            isEnabled: true
        )

        XCTAssertEqual(outcome, .saved)
        let account = try XCTUnwrap(try ledger.fetchAccounts().first)
        XCTAssertNil(account.claudeOrganizationID)
        XCTAssertEqual(
            account.credentialReference,
            AccountCredentialReference.make(accountID: account.id, source: .credential)
        )
        XCTAssertEqual(credentials.saved[account.credentialReference], "sk-ant-admin-secret")
        XCTAssertTrue(signIn.presentedAccounts.isEmpty)
    }

    func testALocalLogsAccountStoresNoSecretAndNeverPresentsSignIn() async throws {
        let ledger = try makeLedger()
        let credentials = RecordingCredentialStore()
        let signIn = FakeSignIn(outcome: .signedIn(organizationID: organizationID))
        let flow = makeFlow(ledger: ledger, credentials: credentials, signIn: signIn)

        let outcome = await flow.save(
            providerID: .claude,
            displayName: "Claude Code",
            source: .localLogs,
            credentialValue: "",
            isEnabled: false
        )

        XCTAssertEqual(outcome, .saved)
        let account = try XCTUnwrap(try ledger.fetchAccounts().first)
        XCTAssertFalse(account.isEnabled)
        XCTAssertNil(account.claudeOrganizationID)
        XCTAssertTrue(account.credentialReference.hasPrefix(ProviderAdapterRegistry.localSourceScheme))
        XCTAssertTrue(credentials.saved.isEmpty)
        XCTAssertTrue(signIn.presentedAccounts.isEmpty)
    }

    /// The web session is Claude's alone. A stray selection on another provider
    /// must not open a claude.ai window for an account that is not Claude — it
    /// falls back to the credential source, exactly as the local source already did.
    func testANonClaudeProviderNeverPresentsSignIn() async throws {
        for providerID in ProviderID.allCases where providerID != .claude {
            let ledger = try makeLedger()
            let credentials = RecordingCredentialStore()
            let signIn = FakeSignIn(outcome: .signedIn(organizationID: organizationID))
            let flow = makeFlow(ledger: ledger, credentials: credentials, signIn: signIn)

            let outcome = await flow.save(
                providerID: providerID,
                displayName: "Elsewhere",
                source: .claudeWebSession,
                credentialValue: "token",
                isEnabled: true
            )

            XCTAssertEqual(outcome, .saved, "\(providerID)")
            XCTAssertTrue(signIn.presentedAccounts.isEmpty, "\(providerID)")

            let account = try XCTUnwrap(try ledger.fetchAccounts().first)
            XCTAssertNil(account.claudeOrganizationID, "\(providerID)")
            XCTAssertEqual(
                account.credentialReference,
                AccountCredentialReference.make(accountID: account.id, source: .credential),
                "\(providerID)"
            )
        }
    }
}
