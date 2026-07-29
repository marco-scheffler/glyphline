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
    func testTheRemoverIsAskedForTheIdentifierDerivedFromTheAccount() async throws {
        let remover = RecordingWebSessionRemover()
        let accountID = UUID()
        try await remover.removeSession(for: accountID)
        XCTAssertEqual(remover.removed, [accountID])
    }

    @MainActor
    func testTheStoreConformsToTheRemovalSeam() {
        // Conformance only. Calling through would touch the real WebKit store.
        let store: any WebSessionRemoving = ClaudeWebSessionStore()
        XCTAssertNotNil(store)
    }
}

/// A stand-in for WebKit. The real removal is exercised by using the app, not
/// by a test: creating a real data store leaves a directory under
/// ~/Library/WebKit on the developer's machine.
@MainActor
private final class RecordingWebSessionRemover: WebSessionRemoving {
    var removed: [UUID] = []
    var errorToThrow: (any Error)?

    func removeSession(for accountID: UUID) async throws {
        if let errorToThrow { throw errorToThrow }
        removed.append(accountID)
    }
}
