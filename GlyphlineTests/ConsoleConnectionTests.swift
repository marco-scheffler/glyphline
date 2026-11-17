import GRDB
import XCTest
@testable import Glyphline

@MainActor
final class ConsoleConnectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private final class StubSignIn: ConsoleSignInPresenting {
        let outcome: ConsoleSignInOutcome
        init(_ outcome: ConsoleSignInOutcome) { self.outcome = outcome }

        func presentConsoleSignIn(for account: Account) async -> ConsoleSignInOutcome {
            outcome
        }
    }

    /// Records the removal together with what the ledger held at that moment,
    /// so the order of disconnect's two steps is observable.
    private final class RecordingRemover: ConsoleSessionRemoving, @unchecked Sendable {
        var events: [String] = []
        var organizationsAtRemoval: [[ConsoleOrganization]] = []
        var store: LedgerStore?

        func removeConsoleSession(for accountID: UUID) async {
            events.append("remove")
            let current = (try? store?.fetchAccounts().first { $0.id == accountID })??.consoleOrganizations
            organizationsAtRemoval.append(current ?? [])
        }
    }

    private func makeAccount(source: AccountSource, providerID: ProviderID = .claude) -> Account {
        let id = UUID()
        return Account(
            id: id,
            providerID: providerID,
            displayName: "Max #1",
            credentialReference: AccountCredentialReference.make(accountID: id, source: source),
            createdAt: now,
            isEnabled: true
        )
    }

    private func makeStore() throws -> LedgerStore {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        return LedgerStore(dbQueue: dbQueue)
    }

    private func storedOrganizations(_ store: LedgerStore, _ id: UUID) throws -> [ConsoleOrganization] {
        try XCTUnwrap(store.fetchAccounts().first { $0.id == id }).consoleOrganizations
    }

    func testOnlyWebSessionClaudeAccountsAreEligible() {
        XCTAssertTrue(makeAccount(source: .claudeWebSession).canConnectConsole)
        XCTAssertFalse(makeAccount(source: .credential).canConnectConsole)
        XCTAssertFalse(makeAccount(source: .localLogs).canConnectConsole)
        XCTAssertFalse(makeAccount(source: .claudeWebSession, providerID: .openAI).canConnectConsole)
    }

    func testConnectPersistsTheReportedOrganizations() async throws {
        let store = try makeStore()
        let account = makeAccount(source: .claudeWebSession)
        try store.saveAccount(account)
        let orgs = [ConsoleOrganization(id: "org-a"), ConsoleOrganization(id: "org-b")]
        let remover = RecordingRemover()

        let connection = ConsoleConnection(ledgerStore: store, signIn: StubSignIn(.connected(orgs)), sessions: remover)
        let outcome = await connection.connect(account)

        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(try storedOrganizations(store, account.id), orgs)
        XCTAssertTrue(remover.events.isEmpty)
    }

    func testFailedOrCancelledConnectPersistsNothingAndRemovesNoSession() async throws {
        for signInOutcome in [ConsoleSignInOutcome.failed(.sessionExpired), .cancelled] {
            let store = try makeStore()
            let account = makeAccount(source: .claudeWebSession)
            try store.saveAccount(account)
            let remover = RecordingRemover()

            let connection = ConsoleConnection(ledgerStore: store, signIn: StubSignIn(signInOutcome), sessions: remover)
            let outcome = await connection.connect(account)

            if case .failed = outcome {} else { XCTFail("\(signInOutcome) must fail, got \(outcome)") }
            XCTAssertEqual(try storedOrganizations(store, account.id), [])
            XCTAssertEqual(remover.events.count, 0, "the claude.ai session shares the store")
        }
    }

    func testDisconnectClearsOrganizationsThenRemovesTheConsoleSession() async throws {
        let store = try makeStore()
        var account = makeAccount(source: .claudeWebSession)
        account.consoleOrganizations = [ConsoleOrganization(id: "org-a")]
        try store.saveAccount(account)
        let remover = RecordingRemover()
        remover.store = store

        let connection = ConsoleConnection(ledgerStore: store, signIn: StubSignIn(.cancelled), sessions: remover)
        let outcome = await connection.disconnect(account)

        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(remover.events, ["remove"])
        XCTAssertEqual(remover.organizationsAtRemoval, [[]], "the ledger is cleared before the session goes")
        XCTAssertEqual(try storedOrganizations(store, account.id), [])
    }

    func testConnectWithNoOrganizationsIsAFailure() async throws {
        let store = try makeStore()
        let account = makeAccount(source: .claudeWebSession)
        try store.saveAccount(account)
        let remover = RecordingRemover()

        let connection = ConsoleConnection(ledgerStore: store, signIn: StubSignIn(.connected([])), sessions: remover)
        let outcome = await connection.connect(account)

        XCTAssertEqual(outcome, .failed("This login has no Claude Console organisation whose credit can be read."))
        XCTAssertEqual(try storedOrganizations(store, account.id), [])
        XCTAssertTrue(remover.events.isEmpty)
    }

    func testNotAvailableSaysThereIsNoReadableOrganization() async throws {
        let store = try makeStore()
        let account = makeAccount(source: .claudeWebSession)
        try store.saveAccount(account)

        let connection = ConsoleConnection(
            ledgerStore: store, signIn: StubSignIn(.failed(.notAvailable)), sessions: RecordingRemover()
        )
        let outcome = await connection.connect(account)

        XCTAssertEqual(outcome, .failed("This login has no Claude Console organisation whose credit can be read."))
        XCTAssertEqual(outcome, .failed(ConsoleConnection.noOrganizationMessage))
    }

    func testAnExpiredSignInUsesTheConsoleWording() async throws {
        let store = try makeStore()
        let account = makeAccount(source: .claudeWebSession)
        try store.saveAccount(account)

        let connection = ConsoleConnection(
            ledgerStore: store, signIn: StubSignIn(.failed(.sessionExpired)), sessions: RecordingRemover()
        )
        let outcome = await connection.connect(account)

        XCTAssertEqual(outcome, .failed(RateWindowSourceError.sessionExpired.consoleMessage))
        XCTAssertNotEqual(outcome, .failed(RateWindowSourceError.sessionExpired.message))
    }
}
