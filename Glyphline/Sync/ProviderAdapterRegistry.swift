import Foundation

/// Decides which adapter, in which mode, serves a given account.
///
/// The decision comes from the account's credential reference. A reference
/// beginning with `local-source://` marks a credential-free local source, one
/// beginning with `web-session://` marks a subscription read through the user's
/// own claude.ai session, and any other reference means a secret stored in the
/// Keychain.
struct ProviderAdapterRegistry {
    static let localSourceScheme = "local-source://"
    /// Its own scheme rather than a reuse of `local-source://`, because the two
    /// resolve to different cost adapters. Sharing the local scheme would give
    /// every web-session subscription a `.localLogs` adapter reading the same
    /// `~/.claude/projects`, and three subscriptions would then report one Mac's
    /// costs three times — a wrong number rather than a visible failure.
    static let webSessionScheme = "web-session://"

    var session: URLSession
    var claudeLogDirectory: URL
    var watermarkStore: (any WatermarkStoring)?
    var sessionStore: ClaudeWebSessionStore = ClaudeWebSessionStore()

    init(
        session: URLSession = .shared,
        claudeLogDirectory: URL = ProviderAdapterRegistry.defaultClaudeLogDirectory,
        watermarkStore: (any WatermarkStoring)? = nil
    ) {
        self.session = session
        self.claudeLogDirectory = claudeLogDirectory
        self.watermarkStore = watermarkStore
    }

    static var defaultClaudeLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    func adapter(for account: Account) -> any ProviderAdapter {
        let isLocal = account.credentialReference.hasPrefix(Self.localSourceScheme)
        let isWebSession = account.credentialReference.hasPrefix(Self.webSessionScheme)

        switch account.providerID {
        case .openAI:
            return OpenAIUsageAdapter(session: session)
        case .claude:
            // Quota only. This account has no admin key and its costs are not its
            // own to report, so the adapter says exactly that instead of reading a
            // log directory that belongs to a different account.
            if isWebSession {
                return ClaudeUsageAdapter(mode: .webSessionQuotaOnly, session: session)
            }

            guard isLocal else {
                return ClaudeUsageAdapter(mode: .adminAPI, session: session)
            }

            let reader = watermarkStore.map {
                ClaudeCodeLogReader(directory: claudeLogDirectory, watermarkStore: $0)
            }
            return ClaudeUsageAdapter(mode: .localLogs, session: session, logReader: reader)
        case .cursor:
            return CursorUsageAdapter(mode: isLocal ? .localStatusOnly : .teamAPI, session: session)
        }
    }

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
