import GRDB
import XCTest
@testable import Glyphline

/// Renaming an account: the override, its fallback, and the one rule that says
/// what counts as no name at all.
@MainActor
final class AccountRenameTests: XCTestCase {
    private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> LedgerStore {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        return LedgerStore(dbQueue: dbQueue)
    }

    private func makeAccount(_ derived: String) -> Account {
        let id = UUID()
        return Account(
            id: id,
            providerID: .claude,
            displayName: derived,
            credentialReference: "local-source://\(id.uuidString)",
            createdAt: createdAt,
            isEnabled: true
        )
    }

    private func fetched(_ store: LedgerStore, _ id: UUID) throws -> Account {
        let account = try store.fetchAccounts().first { $0.id == id }
        return try XCTUnwrap(account)
    }

    /// The whole point of the feature: a chosen name has to survive the write and
    /// the read back. Catches a `customName` that never reaches the row — drop it
    /// from the `UPDATE`'s SET clause and the fetched account is still
    /// "Claude personal".
    func testARenamedAccountRoundTripsThroughTheStore() throws {
        let store = try makeStore()
        let account = makeAccount("Claude personal")
        try store.saveAccount(account)

        try store.renameAccount(accountID: account.id, to: "Work")

        let reloaded = try fetched(store, account.id)
        XCTAssertEqual(reloaded.customName, "Work")
        XCTAssertEqual(reloaded.resolvedName, "Work")
        XCTAssertEqual(
            reloaded.displayName,
            "Claude personal",
            "the derived name has to stay, or there is nothing to fall back to"
        )
    }

    /// Clearing must hand the account back to its derived name rather than leave
    /// it blank. Catches `resolvedName` returning `customName ?? ""` or the
    /// rename writing an empty string instead of NULL.
    func testClearingTheNameFallsBackToTheDerivedOne() throws {
        let store = try makeStore()
        let account = makeAccount("Claude gpt_personal")
        try store.saveAccount(account)
        try store.renameAccount(accountID: account.id, to: "Personal")

        try store.renameAccount(accountID: account.id, to: "")

        let reloaded = try fetched(store, account.id)
        XCTAssertNil(reloaded.customName)
        XCTAssertEqual(reloaded.resolvedName, "Claude gpt_personal")
    }

    /// Whitespace is not a name. Catches a `renameAccount` that stores the raw
    /// string — without the trim the account is called "   " everywhere it
    /// appears, which reads as a bug with no way to explain itself.
    func testAWhitespaceOnlyNameIsTreatedAsCleared() throws {
        let store = try makeStore()
        let account = makeAccount("Claude personal-2")
        try store.saveAccount(account)
        try store.renameAccount(accountID: account.id, to: "Work")

        try store.renameAccount(accountID: account.id, to: "  \n ")

        let reloaded = try fetched(store, account.id)
        XCTAssertNil(reloaded.customName)
        XCTAssertEqual(reloaded.resolvedName, "Claude personal-2")
    }

    /// A name that is real but padded keeps its content and loses the padding —
    /// the same single rule, seen from the other side.
    func testANameIsStoredTrimmed() throws {
        let store = try makeStore()
        let account = makeAccount("Claude personal")
        try store.saveAccount(account)

        try store.renameAccount(accountID: account.id, to: "  Work  ")

        XCTAssertEqual(try fetched(store, account.id).customName, "Work")
    }

    /// Catches the missing `WHERE` clause — an `UPDATE accounts SET customName`
    /// without it renames every account in the ledger to the same thing, and the
    /// user only finds out by looking at the other card.
    func testRenamingOneAccountDoesNotTouchAnother() throws {
        let store = try makeStore()
        let renamed = makeAccount("Claude personal")
        let untouched = makeAccount("Claude personal-2")
        try store.saveAccount(renamed)
        try store.saveAccount(untouched)

        try store.renameAccount(accountID: renamed.id, to: "Work")

        XCTAssertEqual(try fetched(store, renamed.id).resolvedName, "Work")
        XCTAssertEqual(try fetched(store, untouched.id).resolvedName, "Claude personal-2")
        XCTAssertNil(try fetched(store, untouched.id).customName)
    }

    /// `saveAccount` is the other writer of this column. An upsert that forgot it
    /// would silently drop a chosen name on the next sync write.
    func testSaveAccountCarriesTheChosenNameThroughItsUpsert() throws {
        let store = try makeStore()
        var account = makeAccount("Claude personal")
        try store.saveAccount(account)

        account.rename(to: "Work")
        try store.saveAccount(account)

        XCTAssertEqual(try fetched(store, account.id).customName, "Work")
    }

    // MARK: - The rule itself

    /// The normalisation lives in one place, so it is asserted in one place.
    func testRenameOnTheModelAppliesTheSameRule() {
        var account = makeAccount("Claude personal")

        account.rename(to: " Work ")
        XCTAssertEqual(account.customName, "Work")

        account.rename(to: "\t ")
        XCTAssertNil(account.customName, "whitespace only is no name")
        XCTAssertEqual(account.resolvedName, "Claude personal")

        account.rename(to: nil)
        XCTAssertNil(account.customName)
    }

    // MARK: - What the dashboard shows

    private func summary(for account: Account) -> AccountUsageSummary {
        AccountUsageSummary(
            account: account,
            capabilities: nil,
            billingPeriod: nil,
            latestSyncRun: nil,
            inputTokens: 0,
            outputTokens: 0,
            requestCount: nil,
            actualAmountMicros: nil,
            estimatedAmountMicros: nil,
            displayCurrency: nil,
            dataQuality: .exact
        )
    }

    /// The card is where the name actually pays off. Catches the card being built
    /// from `displayName` — with the override set, the dashboard would keep
    /// showing "Claude personal" while the Accounts tab shows "Work".
    func testTheQuotaCardShowsTheChosenNameWhenThereIsOne() {
        var account = makeAccount("Claude personal")
        account.rename(to: "Work")

        let card = DashboardPresentation.accountQuotaCard(
            summary: summary(for: account),
            state: nil,
            now: createdAt
        )

        XCTAssertEqual(card.accountName, "Work")
    }

    /// And the other half: with no override the card must still be named, never
    /// blank — the guarantee the non-optional `accountName` exists to keep.
    func testTheQuotaCardFallsBackToTheDerivedNameOnTheCardWithWindows() {
        var account = makeAccount("Claude personal")
        account.rename(to: "   ")

        let state = QuotaAccountState(
            accountID: account.id,
            displayName: "Claude personal",
            windows: [],
            message: nil
        )
        let card = DashboardPresentation.accountQuotaCard(
            summary: summary(for: account),
            state: state,
            now: createdAt
        )

        XCTAssertEqual(card.accountName, "Claude personal")
        XCTAssertFalse(card.accountName.isEmpty)
    }
}
