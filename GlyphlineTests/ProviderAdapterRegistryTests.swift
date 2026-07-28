import XCTest
@testable import Glyphline

final class ProviderAdapterRegistryTests: XCTestCase {
    private func makeAccount(_ providerID: ProviderID, reference: String) -> Account {
        Account(
            id: UUID(),
            providerID: providerID,
            displayName: "Test",
            credentialReference: reference,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
    }

    func testKeychainBackedClaudeAccountUsesAdminAPI() throws {
        let registry = ProviderAdapterRegistry()
        let account = makeAccount(.claude, reference: "keychain://glyphline/abc")

        let adapter = try XCTUnwrap(registry.adapter(for: account) as? ClaudeUsageAdapter)
        XCTAssertEqual(adapter.mode, .adminAPI)
        XCTAssertTrue(adapter.requiresSecret)
    }

    func testLocalSourceClaudeAccountUsesLocalLogs() throws {
        let registry = ProviderAdapterRegistry()
        let account = makeAccount(.claude, reference: "local-source://claude-code")

        let adapter = try XCTUnwrap(registry.adapter(for: account) as? ClaudeUsageAdapter)
        XCTAssertEqual(adapter.mode, .localLogs)
        XCTAssertFalse(adapter.requiresSecret)
    }

    func testKeychainBackedCursorAccountUsesTeamAPI() throws {
        let registry = ProviderAdapterRegistry()
        let account = makeAccount(.cursor, reference: "keychain://glyphline/abc")

        let adapter = try XCTUnwrap(registry.adapter(for: account) as? CursorUsageAdapter)
        XCTAssertEqual(adapter.mode, .teamAPI)
    }

    func testLocalSourceCursorAccountUsesLocalStatusOnly() throws {
        let registry = ProviderAdapterRegistry()
        let account = makeAccount(.cursor, reference: "local-source://cursor")

        let adapter = try XCTUnwrap(registry.adapter(for: account) as? CursorUsageAdapter)
        XCTAssertEqual(adapter.mode, .localStatusOnly)
    }

    func testOpenAIAccountUsesUsageAdapter() throws {
        let registry = ProviderAdapterRegistry()
        let account = makeAccount(.openAI, reference: "keychain://glyphline/abc")

        XCTAssertTrue(registry.adapter(for: account) is OpenAIUsageAdapter)
    }

    /// An account with no quota credential has no quota source at all — it must
    /// resolve to nil rather than to a source that would fail on every tick.
    func testAnAccountWithoutAQuotaCredentialHasNoRateWindowSource() throws {
        let registry = ProviderAdapterRegistry()
        let account = makeAccount(.claude, reference: "local-source://claude-code")

        XCTAssertNil(account.quotaCredentialReference)
        XCTAssertNil(registry.rateWindowSource(for: account))
    }

    func testAnAccountWithAQuotaCredentialResolvesToARateWindowSource() throws {
        let registry = ProviderAdapterRegistry()
        var account = makeAccount(.claude, reference: "local-source://claude-code")
        account.quotaCredentialReference = "keychain://glyphline/quota-token"

        let source = try XCTUnwrap(registry.rateWindowSource(for: account))
        XCTAssertTrue(source is FixtureRateWindowSource)
    }
}
