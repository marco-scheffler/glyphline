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
        let view = AccountsView(accounts: [], onAdded: { reloads += 1 })

        view.accountSaved()

        XCTAssertEqual(reloads, 1)
    }

    func testDeletingAnAccountStillUsesItsOwnCallback() {
        var adds = 0
        var deletes = 0
        let view = AccountsView(accounts: [], onDeleted: { deletes += 1 }, onAdded: { adds += 1 })

        view.accountSaved()

        XCTAssertEqual(adds, 1)
        XCTAssertEqual(deletes, 0)
    }
}
