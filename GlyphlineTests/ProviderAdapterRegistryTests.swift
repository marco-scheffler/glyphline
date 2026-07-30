import XCTest
@testable import Glyphline

@MainActor
final class ProviderAdapterRegistryTests: XCTestCase {
    private let organizationID = "11111111-1111-1111-1111-111111111111"

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

    /// What the entry point produces end to end: a signed-in web-session account
    /// draws its quota from the web source.
    func testAWebSessionAccountWithAnOrganisationDrawsQuotaFromTheWebSource() throws {
        let registry = ProviderAdapterRegistry()
        var account = makeAccount(.claude, reference: "web-session://\(UUID().uuidString)")
        account.claudeOrganizationID = organizationID

        XCTAssertTrue(registry.rateWindowSource(for: account) is ClaudeWebQuotaSource)
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

    /// An organisation id alone does not make a web session. `fetchWindows` asks
    /// for this account's WebKit data store and that call *creates* one, while
    /// `DeleteAccountFlow` decides whether to remove a store from the credential
    /// reference alone. So a local-source account carrying a stray organisation id
    /// would have a store created on every tick and would never be asked to remove
    /// one — a store keyed on an account id that nothing will ever look up again.
    func testALocalSourceAccountWithAnOrganisationHasNoRateWindowSource() throws {
        let registry = ProviderAdapterRegistry()
        var account = makeAccount(.claude, reference: "local-source://claude-code")
        account.claudeOrganizationID = organizationID

        XCTAssertEqual(
            AccountCredentialReference.source(of: account.credentialReference),
            .localLogs
        )
        XCTAssertNil(registry.rateWindowSource(for: account))
    }

    /// Before the sign-in there is no organisation, so there is no route — and a
    /// source resolved anyway would navigate on every tick and fail every time.
    ///
    /// Asserted on a web-session account, so the reference is not what makes this
    /// nil: the missing organisation is.
    func testAClaudeAccountWithoutAnOrganisationHasNoRateWindowSource() throws {
        let registry = ProviderAdapterRegistry()
        let account = makeAccount(.claude, reference: "web-session://\(UUID().uuidString)")

        XCTAssertNil(account.claudeOrganizationID)
        XCTAssertNil(registry.rateWindowSource(for: account))
    }

    /// The organisation id is Claude's alone. A stray value on another provider
    /// must not open a claude.ai navigation for an account that is not Claude.
    ///
    /// Given the web-session reference too, so the provider check is the only
    /// thing left standing between this account and a source.
    func testANonClaudeAccountNeverResolvesToTheWebSource() throws {
        let registry = ProviderAdapterRegistry()

        for providerID in ProviderID.allCases where providerID != .claude {
            var account = makeAccount(providerID, reference: "web-session://\(UUID().uuidString)")
            account.claudeOrganizationID = organizationID

            XCTAssertNil(registry.rateWindowSource(for: account), "\(providerID)")
        }
    }

    /// An empty string is not an organisation. `ClaudeWebEndpoints.usage` rejects
    /// it, so resolving a source would guarantee a failing tick and a message the
    /// user cannot act on.
    func testAnEmptyOrganisationIdIsNotAnOrganisation() throws {
        let registry = ProviderAdapterRegistry()
        var account = makeAccount(.claude, reference: "web-session://\(UUID().uuidString)")
        account.claudeOrganizationID = ""

        XCTAssertNil(registry.rateWindowSource(for: account))
    }
}
