import XCTest
@testable import Glyphline

final class AccountCredentialReferenceTests: XCTestCase {
    func testKeychainReferenceCarriesTheAccountID() {
        let id = UUID()
        let reference = AccountCredentialReference.make(accountID: id, usesLocalSource: false)

        XCTAssertEqual(reference, "keychain://glyphline/\(id.uuidString)")
        XCTAssertFalse(reference.hasPrefix(ProviderAdapterRegistry.localSourceScheme))
    }

    func testLocalSourceReferenceIsRecognisedByTheRegistry() {
        let id = UUID()
        let reference = AccountCredentialReference.make(accountID: id, usesLocalSource: true)

        XCTAssertTrue(reference.hasPrefix(ProviderAdapterRegistry.localSourceScheme))

        let account = Account(
            id: id,
            providerID: .claude,
            displayName: "Local",
            credentialReference: reference,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
        let adapter = ProviderAdapterRegistry().adapter(for: account) as? ClaudeUsageAdapter

        XCTAssertEqual(adapter?.mode, .localLogs)
    }
}
