import GRDB
import XCTest
@testable import Glyphline

@MainActor
final class DeleteAccountFlowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private final class StubRemover: WebSessionRemoving {
        var removed: [UUID] = []
        var errorToThrow: (any Error)?

        func removeSession(for accountID: UUID) async throws {
            if let errorToThrow { throw errorToThrow }
            removed.append(accountID)
        }
    }

    private struct StubError: Error {}

    private func makeAccount(source: AccountSource) -> Account {
        let id = UUID()
        return Account(
            id: id,
            providerID: .claude,
            displayName: "Max #1",
            credentialReference: AccountCredentialReference.make(accountID: id, source: source),
            createdAt: now,
            isEnabled: true
        )
    }

    private func makeStore() throws -> (LedgerStore, DatabaseQueue) {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        return (LedgerStore(dbQueue: dbQueue), dbQueue)
    }

    private func accountCount(_ dbQueue: DatabaseQueue) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts") ?? 0
        }
    }

    func testTheReferenceRoundTripsThroughItsSource() {
        for source in AccountSource.allCases {
            let id = UUID()
            let reference = AccountCredentialReference.make(accountID: id, source: source)
            XCTAssertEqual(AccountCredentialReference.source(of: reference), source)
        }
    }

    func testDeletingRemovesTheAccount() async throws {
        let (store, dbQueue) = try makeStore()
        let account = makeAccount(source: .localLogs)
        try store.saveAccount(account)

        let flow = DeleteAccountFlow(
            ledgerStore: store,
            credentialStore: InMemoryCredentialStore(),
            webSessions: StubRemover()
        )
        let outcome = await flow.delete(account)

        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(try accountCount(dbQueue), 0)
    }

    func testAWebSessionAccountHasItsSessionRemoved() async throws {
        let (store, _) = try makeStore()
        let account = makeAccount(source: .claudeWebSession)
        try store.saveAccount(account)

        let remover = StubRemover()
        let flow = DeleteAccountFlow(
            ledgerStore: store,
            credentialStore: InMemoryCredentialStore(),
            webSessions: remover
        )
        let outcome = await flow.delete(account)

        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(remover.removed, [account.id])
    }

    func testAnAccountWithoutAWebSessionIsNotAskedToRemoveOne() async throws {
        let (store, _) = try makeStore()
        let account = makeAccount(source: .localLogs)
        try store.saveAccount(account)

        let remover = StubRemover()
        let flow = DeleteAccountFlow(
            ledgerStore: store,
            credentialStore: InMemoryCredentialStore(),
            webSessions: remover
        )
        _ = await flow.delete(account)

        XCTAssertTrue(remover.removed.isEmpty)
    }

    func testACredentialAccountHasItsSecretDeleted() async throws {
        let (store, _) = try makeStore()
        let account = makeAccount(source: .credential)
        try store.saveAccount(account)

        let credentials = InMemoryCredentialStore()
        try credentials.save(secret: "value", for: account.credentialReference)

        let flow = DeleteAccountFlow(
            ledgerStore: store,
            credentialStore: credentials,
            webSessions: StubRemover()
        )
        _ = await flow.delete(account)

        XCTAssertNil(try credentials.readSecret(for: account.credentialReference))
    }

    func testAQuotaSecretIsDeletedToo() async throws {
        let (store, _) = try makeStore()
        var account = makeAccount(source: .localLogs)
        account.quotaCredentialReference = "keychain://glyphline/quota-\(account.id.uuidString)"
        try store.saveAccount(account)

        let credentials = InMemoryCredentialStore()
        try credentials.save(secret: "quota", for: account.quotaCredentialReference!)

        let flow = DeleteAccountFlow(
            ledgerStore: store,
            credentialStore: credentials,
            webSessions: StubRemover()
        )
        _ = await flow.delete(account)

        XCTAssertNil(try credentials.readSecret(for: account.quotaCredentialReference!))
    }

    /// The ordering invariant, and the reason this flow exists. If removing the
    /// session fails, the account must still be there — an account whose row is
    /// gone but whose session is not can never be found again.
    func testAFailedSessionRemovalLeavesTheAccountIntact() async throws {
        let (store, dbQueue) = try makeStore()
        let account = makeAccount(source: .claudeWebSession)
        try store.saveAccount(account)

        let remover = StubRemover()
        remover.errorToThrow = StubError()
        let flow = DeleteAccountFlow(
            ledgerStore: store,
            credentialStore: InMemoryCredentialStore(),
            webSessions: remover
        )
        let outcome = await flow.delete(account)

        XCTAssertEqual(outcome, .failed(DeleteAccountFlow.webSessionCleanupFailedMessage))
        XCTAssertEqual(try accountCount(dbQueue), 1)
    }

    /// The combination that used to lose a token: a web-session account that also
    /// holds a quota secret. If the session removal fails, nothing may have been
    /// taken from the account yet — the message promises exactly that.
    func testAFailedSessionRemovalLeavesAQuotaSecretIntact() async throws {
        let (store, dbQueue) = try makeStore()
        var account = makeAccount(source: .claudeWebSession)
        account.quotaCredentialReference = "keychain://glyphline/quota-\(account.id.uuidString)"
        try store.saveAccount(account)

        let credentials = InMemoryCredentialStore()
        try credentials.save(secret: "quota", for: account.quotaCredentialReference!)

        let remover = StubRemover()
        remover.errorToThrow = StubError()
        let flow = DeleteAccountFlow(
            ledgerStore: store,
            credentialStore: credentials,
            webSessions: remover
        )
        let outcome = await flow.delete(account)

        XCTAssertEqual(outcome, .failed(DeleteAccountFlow.webSessionCleanupFailedMessage))
        XCTAssertNotNil(try credentials.readSecret(for: account.quotaCredentialReference!))
        XCTAssertEqual(try accountCount(dbQueue), 1)
    }

    func testTheFailureMessageNamesNoIdentifier() async throws {
        let (store, _) = try makeStore()
        let account = makeAccount(source: .claudeWebSession)
        try store.saveAccount(account)

        let remover = StubRemover()
        remover.errorToThrow = StubError()
        let flow = DeleteAccountFlow(
            ledgerStore: store,
            credentialStore: InMemoryCredentialStore(),
            webSessions: remover
        )
        guard case let .failed(message) = await flow.delete(account) else {
            return XCTFail("expected a failure")
        }
        XCTAssertFalse(message.contains(account.id.uuidString))
        XCTAssertFalse(message.contains("web-session://"))
    }
}
