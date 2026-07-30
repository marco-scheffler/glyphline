import Foundation

/// Decides which quota source, if any, serves a given account.
///
/// The decision comes from the account's credential reference. A reference
/// beginning with `local-source://` marks a credential-free local source, one
/// beginning with `web-session://` marks a subscription read through the user's
/// own claude.ai session, and any other reference means a secret stored in the
/// Keychain.
struct ProviderAdapterRegistry {
    static let localSourceScheme = "local-source://"
    /// Its own scheme rather than a reuse of `local-source://`: a web-session
    /// subscription is reached through the user's own claude.ai session, which is
    /// a different thing from a local directory on this Mac, and only the former
    /// resolves to a quota source.
    static let webSessionScheme = "web-session://"

    var sessionStore: ClaudeWebSessionStore = ClaudeWebSessionStore()

    /// The quota source for an account.
    ///
    /// Exactly one account shape resolves to anything: a Claude account that
    /// carries the web-session scheme *and* whose sign-in resolved an organisation
    /// id. The id is what the usage endpoint's path is built from, so without it
    /// there is no route — and a source handed back anyway would navigate on every
    /// tick and fail every time.
    ///
    /// The reference is read as well as the id, and it has to be: `fetchWindows`
    /// asks `ClaudeWebSessionStore` for this account's data store, and that call
    /// *creates* one. `DeleteAccountFlow` decides whether to remove a store from
    /// the reference alone, so an account with some other reference and a stray
    /// organisation id would have a store created on every tick and would never be
    /// asked to remove one — the same unnameable orphan, arrived at from the other
    /// end. One predicate, read the same way in both places.
    ///
    /// Everything else stays `nil`. This used to hand back
    /// `FixtureRateWindowSource` for any account carrying a quota credential
    /// reference; the fixture invents figures — 62% and 31% — and nothing
    /// downstream distinguishes an invented figure from a measured one, so that
    /// path wrote fabricated numbers into the ledger and rendered them as fact.
    /// The fixture stays in the target for tests, which inject it directly
    /// through `SyncCoordinator(rateWindowSourceProvider:)`.
    ///
    /// `@MainActor` because `ClaudeWebQuotaSource` is: it drives a `WKWebView`.
    @MainActor
    func rateWindowSource(for account: Account) -> (any RateWindowSource)? {
        guard account.providerID == .claude,
              AccountCredentialReference.source(of: account.credentialReference) == .claudeWebSession,
              let organizationID = account.claudeOrganizationID,
              !organizationID.isEmpty
        else {
            return nil
        }

        return ClaudeWebQuotaSource(sessionStore: sessionStore)
    }
}
