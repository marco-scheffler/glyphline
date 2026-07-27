import Security
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

    func testKeychainStoreUpdatesExistingCredentialWithoutDelete() throws {
        let client = MockKeychainClient(updateStatus: errSecSuccess)
        let store = KeychainStore(service: "test.service", client: client)

        try store.save(secret: "sk-live", for: "account")

        XCTAssertEqual(client.calls, [.update])
        XCTAssertEqual(client.updateAttributes[kSecValueData as String] as? Data, Data("sk-live".utf8))
        XCTAssertEqual(client.deleteCallCount, 0)
        XCTAssertEqual(client.addCallCount, 0)
    }

    func testKeychainStoreAddsCredentialWhenUpdateMissing() throws {
        let client = MockKeychainClient(updateStatus: errSecItemNotFound, addStatus: errSecSuccess)
        let store = KeychainStore(service: "test.service", client: client)

        try store.save(secret: "sk-live", for: "account")

        XCTAssertEqual(client.calls, [.update, .add])
        XCTAssertEqual(client.addQuery[kSecAttrAccount as String] as? String, "account")
        XCTAssertEqual(client.deleteCallCount, 0)
    }

    func testKeychainStoreThrowsWithoutDeleteWhenReplacementWriteFails() {
        let client = MockKeychainClient(updateStatus: errSecItemNotFound, addStatus: errSecAuthFailed)
        let store = KeychainStore(service: "test.service", client: client)

        XCTAssertThrowsError(try store.save(secret: "sk-live", for: "account")) { error in
            XCTAssertEqual(error as? KeychainError, .status(errSecAuthFailed))
        }
        XCTAssertEqual(client.calls, [.update, .add])
        XCTAssertEqual(client.deleteCallCount, 0)
    }
}

private final class MockKeychainClient: KeychainClient {
    enum Call: Equatable {
        case update
        case add
        case copyMatching
        case delete
    }

    var updateStatus: OSStatus
    var addStatus: OSStatus
    var copyData: Data?
    var copyError: Error?
    var deleteStatus: OSStatus

    private(set) var calls: [Call] = []
    private(set) var updateQuery: [String: Any] = [:]
    private(set) var updateAttributes: [String: Any] = [:]
    private(set) var addQuery: [String: Any] = [:]
    private(set) var copyQuery: [String: Any] = [:]
    private(set) var deleteQuery: [String: Any] = [:]
    private(set) var deleteCallCount = 0
    private(set) var addCallCount = 0

    init(
        updateStatus: OSStatus,
        addStatus: OSStatus = errSecSuccess,
        copyData: Data? = nil,
        copyError: Error? = nil,
        deleteStatus: OSStatus = errSecSuccess
    ) {
        self.updateStatus = updateStatus
        self.addStatus = addStatus
        self.copyData = copyData
        self.copyError = copyError
        self.deleteStatus = deleteStatus
    }

    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        calls.append(.update)
        updateQuery = query
        updateAttributes = attributes
        return updateStatus
    }

    func add(query: [String: Any]) -> OSStatus {
        calls.append(.add)
        addCallCount += 1
        addQuery = query
        return addStatus
    }

    func copyMatching(query: [String: Any]) throws -> Data? {
        calls.append(.copyMatching)
        copyQuery = query
        if let copyError {
            throw copyError
        }
        return copyData
    }

    func delete(query: [String: Any]) -> OSStatus {
        calls.append(.delete)
        deleteCallCount += 1
        deleteQuery = query
        return deleteStatus
    }
}
