import XCTest
@testable import Glyphline

final class ClaudeWebSessionStoreTests: XCTestCase {
    func testEachAccountGetsItsOwnStableIdentifier() {
        let store = ClaudeWebSessionStore()
        let a = UUID(), b = UUID()

        XCTAssertNotEqual(store.dataStoreIdentifier(for: a), store.dataStoreIdentifier(for: b),
                          "two subscriptions sharing a store would share a login")
        XCTAssertEqual(store.dataStoreIdentifier(for: a), store.dataStoreIdentifier(for: a),
                       "an identifier that changes loses the session on every fetch")
    }

    func testTheIdentifierIsDerivedFromTheAccountAndSurvivesANewInstance() {
        let accountID = UUID()
        XCTAssertEqual(
            ClaudeWebSessionStore().dataStoreIdentifier(for: accountID),
            ClaudeWebSessionStore().dataStoreIdentifier(for: accountID),
            "a per-instance identifier would drop every session when the app restarts"
        )
    }

    @MainActor
    func testTheRemovalSeamResolvesToTheIdentifierDerivedFromTheAccount() {
        // Conformance is pinned by the annotation; the assertion is on the
        // derivation, which is the property that makes a store findable for
        // removal at all. Calling removeSession would touch the real WebKit store.
        let store = ClaudeWebSessionStore()
        let _: any WebSessionRemoving = store
        let accountID = UUID()
        XCTAssertEqual(store.dataStoreIdentifier(for: accountID), accountID)
    }
}
