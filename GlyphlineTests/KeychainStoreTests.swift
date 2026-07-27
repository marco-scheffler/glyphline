import XCTest

@testable import Glyphline

final class KeychainStoreTests: XCTestCase {
    func testInMemoryCredentialStoreRoundTripsSecret() throws {
        let store = InMemoryCredentialStore()

        try store.save(secret: "sk-test", for: "openai-personal")
        XCTAssertEqual(try store.readSecret(for: "openai-personal"), "sk-test")

        try store.deleteSecret(for: "openai-personal")
        XCTAssertNil(try store.readSecret(for: "openai-personal"))
    }
}
