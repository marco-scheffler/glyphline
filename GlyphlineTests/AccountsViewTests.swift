import XCTest
@testable import Glyphline

@MainActor
final class AccountsViewTests: XCTestCase {
    /// Adding an account used to be its own sidebar destination whose `onSave`
    /// reloaded the dashboard. Now the sheet lives in the accounts list, so the
    /// reload has to be wired there or a freshly saved account is invisible until
    /// the next navigation.
    func testSavingAnAccountReloadsTheAccountsList() {
        var reloads = 0
        // `ledgerStore: nil`, and never omitted. The parameter's default is
        // `LedgerStore.makeDefault()`, which opens the *real* ledger under
        // ~/Library/Application Support and runs its migrations — the test host
        // is the app, so it lands in the app's own container. A test that leaves
        // it out migrates the user's database and races whatever installed copy
        // is running against it.
        let view = AccountsView(accounts: [], ledgerStore: nil, onAdded: { reloads += 1 })

        view.accountSaved()

        XCTAssertEqual(reloads, 1)
    }

    func testDeletingAnAccountStillUsesItsOwnCallback() {
        var adds = 0
        var deletes = 0
        let view = AccountsView(
            accounts: [],
            ledgerStore: nil,
            onDeleted: { deletes += 1 },
            onAdded: { adds += 1 }
        )

        view.accountSaved()

        XCTAssertEqual(adds, 1)
        XCTAssertEqual(deletes, 0)
    }

    /// The rename has to reach the ledger *and* reload the list. The row renders
    /// from the parent's `accounts`, so a write without the callback leaves the
    /// old name on screen and looks like the rename did nothing.
    func testRenamingAnAccountWritesItAndReloadsTheList() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        let store = LedgerStore(dbQueue: dbQueue)
        let id = UUID()
        try store.saveAccount(
            Account(
                id: id,
                providerID: .claude,
                displayName: "Claude personal",
                credentialReference: "local-source://\(id.uuidString)",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                isEnabled: true
            )
        )

        var reloads = 0
        let view = AccountsView(accounts: [], ledgerStore: store, onRenamed: { reloads += 1 })

        view.commitRename(accountID: id, name: " Work ")

        XCTAssertEqual(try store.fetchAccounts().first?.resolvedName, "Work")
        XCTAssertEqual(reloads, 1)
    }
}
