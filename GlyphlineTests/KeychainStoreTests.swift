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

    /// Two accounts syncing at once put concurrent saves and reads on one store. Unsynchronized
    /// dictionary mutation corrupts the heap rather than merely returning a stale value, so this
    /// hammers both paths and asserts every read returns a value the store was actually given.
    func testInMemoryCredentialStoreSurvivesConcurrentSaveAndRead() throws {
        let store = InMemoryCredentialStore()
        let references = (0..<32).map { "openai-account-\($0)" }
        for reference in references {
            try store.save(secret: "seed", for: reference)
        }

        DispatchQueue.concurrentPerform(iterations: 256) { iteration in
            let reference = references[iteration % references.count]
            if iteration.isMultiple(of: 2) {
                try? store.save(secret: "sk-\(iteration)", for: reference)
            } else {
                let secret = try? store.readSecret(for: reference)
                XCTAssertNotNil(secret)
                XCTAssertTrue(secret?.hasPrefix("s") == true)
            }
        }

        for reference in references {
            XCTAssertNotNil(try store.readSecret(for: reference))
        }
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

/// `@unchecked` asserts exactly one thing: every access to this double's mutable state happens while
/// `lock` is held. That holds because all stored state is private, reached only through the accessors
/// and methods below, and each one takes the lock for the whole access.
private final class MockKeychainClient: KeychainClient, @unchecked Sendable {
    enum Call: Equatable {
        case update
        case add
        case copyMatching
        case delete
    }

    let updateStatus: OSStatus
    let addStatus: OSStatus
    let copyData: Data?
    let copyError: (any Error)?
    let deleteStatus: OSStatus

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _updateQuery: [String: Any] = [:]
    private var _updateAttributes: [String: Any] = [:]
    private var _addQuery: [String: Any] = [:]
    private var _copyQuery: [String: Any] = [:]
    private var _deleteQuery: [String: Any] = [:]
    private var _deleteCallCount = 0
    private var _addCallCount = 0

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var calls: [Call] { withLock { _calls } }
    var updateQuery: [String: Any] { withLock { _updateQuery } }
    var updateAttributes: [String: Any] { withLock { _updateAttributes } }
    var addQuery: [String: Any] { withLock { _addQuery } }
    var copyQuery: [String: Any] { withLock { _copyQuery } }
    var deleteQuery: [String: Any] { withLock { _deleteQuery } }
    var deleteCallCount: Int { withLock { _deleteCallCount } }
    var addCallCount: Int { withLock { _addCallCount } }

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
        withLock {
            _calls.append(.update)
            _updateQuery = query
            _updateAttributes = attributes
        }
        return updateStatus
    }

    func add(query: [String: Any]) -> OSStatus {
        withLock {
            _calls.append(.add)
            _addCallCount += 1
            _addQuery = query
        }
        return addStatus
    }

    func copyMatching(query: [String: Any]) throws -> Data? {
        withLock {
            _calls.append(.copyMatching)
            _copyQuery = query
        }
        if let copyError {
            throw copyError
        }
        return copyData
    }

    func delete(query: [String: Any]) -> OSStatus {
        withLock {
            _calls.append(.delete)
            _deleteCallCount += 1
            _deleteQuery = query
        }
        return deleteStatus
    }
}
