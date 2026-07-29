import XCTest
@testable import Glyphline

final class AccountCredentialReferenceTests: XCTestCase {
    func testKeychainReferenceCarriesTheAccountID() {
        let id = UUID()
        let reference = AccountCredentialReference.make(accountID: id, source: .credential)

        XCTAssertEqual(reference, "keychain://glyphline/\(id.uuidString)")
        XCTAssertFalse(reference.hasPrefix(ProviderAdapterRegistry.localSourceScheme))
    }

    func testLocalSourceReferenceIsRecognisedByTheRegistry() {
        let id = UUID()
        let reference = AccountCredentialReference.make(accountID: id, source: .localLogs)

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

    /// The three schemes are three different answers to "where does this account's
    /// data come from", and the registry tells them apart by prefix alone. A
    /// web-session reference that matched the local prefix would send every
    /// subscription to the same `~/.claude/projects` and report one Mac's costs
    /// once per account.
    func testWebSessionReferenceIsItsOwnSchemeAndNotTheLocalOne() {
        let id = UUID()
        let reference = AccountCredentialReference.make(accountID: id, source: .claudeWebSession)

        XCTAssertEqual(reference, "\(ProviderAdapterRegistry.webSessionScheme)\(id.uuidString)")
        XCTAssertFalse(reference.hasPrefix(ProviderAdapterRegistry.localSourceScheme))
        XCTAssertFalse(reference.hasPrefix("keychain://"))
    }

    /// The reference is a pointer and never a secret — including for the source
    /// whose secret is a live browser session.
    func testEverySourceProducesADistinctReferenceForTheSameAccount() {
        let id = UUID()
        let references = AccountSource.allCases.map {
            AccountCredentialReference.make(accountID: id, source: $0)
        }

        XCTAssertEqual(Set(references).count, AccountSource.allCases.count)
        for reference in references {
            XCTAssertTrue(reference.hasSuffix(id.uuidString))
        }
    }
}
