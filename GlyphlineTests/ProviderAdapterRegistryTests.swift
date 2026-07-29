import XCTest
@testable import Glyphline

@MainActor
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

    /// The cost path for a web-session subscription. It must NOT be `.localLogs`:
    /// that mode reads `~/.claude/projects`, so three web-session accounts would
    /// each report the same local logs and treble the cost figures — wrong numbers
    /// rather than a visible failure.
    func testWebSessionClaudeAccountNeverReadsTheLocalLogs() throws {
        let registry = ProviderAdapterRegistry()
        let account = makeAccount(.claude, reference: "web-session://\(UUID().uuidString)")

        let adapter = try XCTUnwrap(registry.adapter(for: account) as? ClaudeUsageAdapter)
        XCTAssertEqual(adapter.mode, .webSessionQuotaOnly)
        XCTAssertNotEqual(adapter.mode, .localLogs)
        XCTAssertNotEqual(adapter.mode, .adminAPI)
        // There is no secret behind a web session, so the scheduler must not look
        // for one and fail the whole sync when it finds nothing.
        XCTAssertFalse(adapter.requiresSecret)
    }

    /// The scheme the registry reads is the one the Add Account screen writes.
    func testTheWebSessionSchemeIsTheOneTheReferenceBuilderProduces() throws {
        let registry = ProviderAdapterRegistry()
        let id = UUID()
        let reference = AccountCredentialReference.make(accountID: id, source: .claudeWebSession)
        let account = makeAccount(.claude, reference: reference)

        let adapter = try XCTUnwrap(registry.adapter(for: account) as? ClaudeUsageAdapter)
        XCTAssertEqual(adapter.mode, .webSessionQuotaOnly)
    }

    /// The pairing the entry point produces end to end: quota comes from the web
    /// session, cost reports honestly that it has none.
    func testAWebSessionAccountWithAnOrganisationDrawsQuotaFromTheWebSource() throws {
        let registry = ProviderAdapterRegistry()
        var account = makeAccount(.claude, reference: "web-session://\(UUID().uuidString)")
        account.claudeOrganizationID = "22bb9ef8-0000-4c2f-8f0e-000000000001"

        XCTAssertTrue(registry.rateWindowSource(for: account) is ClaudeWebQuotaSource)
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

    /// The registry used to hand back `FixtureRateWindowSource` here, whose
    /// invented 62% and 31% would have been written to the ledger and rendered as
    /// fact, indistinguishable from a measured figure.
    ///
    /// A quota credential still resolves to nothing: the only real source is the
    /// Claude web session, which is keyed off a resolved organisation id and not
    /// off a stored token. Asserted for every provider and with a quota credential
    /// present, because the reason the fabricated path never shipped was an
    /// accident of no screen setting `quotaCredentialReference` — not a decision
    /// this test can rely on.
    func testNoAccountResolvesToAFabricatedRateWindowSource() throws {
        let registry = ProviderAdapterRegistry()

        for providerID in ProviderID.allCases {
            var account = makeAccount(providerID, reference: "keychain://glyphline/abc")
            account.quotaCredentialReference = "keychain://glyphline/quota-token"

            XCTAssertNil(
                registry.rateWindowSource(for: account),
                "\(providerID) must not resolve to a source that invents figures"
            )
        }
    }

    /// The wiring that makes the feature exist: a Claude account whose sign-in
    /// resolved an organisation reads quota through its own web session.
    func testAClaudeAccountWithAnOrganisationResolvesToTheWebSource() throws {
        let registry = ProviderAdapterRegistry()
        var account = makeAccount(.claude, reference: "local-source://claude-code")
        account.claudeOrganizationID = "22bb9ef8-0000-4c2f-8f0e-000000000001"

        XCTAssertTrue(registry.rateWindowSource(for: account) is ClaudeWebQuotaSource)
    }

    /// Before the sign-in there is no organisation, so there is no route — and a
    /// source resolved anyway would navigate on every tick and fail every time.
    func testAClaudeAccountWithoutAnOrganisationHasNoRateWindowSource() throws {
        let registry = ProviderAdapterRegistry()
        let account = makeAccount(.claude, reference: "local-source://claude-code")

        XCTAssertNil(account.claudeOrganizationID)
        XCTAssertNil(registry.rateWindowSource(for: account))
    }

    /// The organisation id is Claude's alone. A stray value on another provider
    /// must not open a claude.ai navigation for an account that is not Claude.
    func testANonClaudeAccountNeverResolvesToTheWebSource() throws {
        let registry = ProviderAdapterRegistry()

        for providerID in ProviderID.allCases where providerID != .claude {
            var account = makeAccount(providerID, reference: "keychain://glyphline/abc")
            account.claudeOrganizationID = "22bb9ef8-0000-4c2f-8f0e-000000000001"

            XCTAssertNil(registry.rateWindowSource(for: account), "\(providerID)")
        }
    }

    /// An empty string is not an organisation. `ClaudeWebEndpoints.usage` rejects
    /// it, so resolving a source would guarantee a failing tick and a message the
    /// user cannot act on.
    func testAnEmptyOrganisationIdIsNotAnOrganisation() throws {
        let registry = ProviderAdapterRegistry()
        var account = makeAccount(.claude, reference: "local-source://claude-code")
        account.claudeOrganizationID = ""

        XCTAssertNil(registry.rateWindowSource(for: account))
    }
}
