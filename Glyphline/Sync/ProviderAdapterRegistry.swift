import Foundation

/// Decides which adapter, in which mode, serves a given account.
///
/// The decision comes from the account's credential reference. A reference
/// beginning with `local-source://` marks a credential-free local source; any
/// other reference means a secret stored in the Keychain.
struct ProviderAdapterRegistry {
    static let localSourceScheme = "local-source://"

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

        switch account.providerID {
        case .openAI:
            return OpenAIUsageAdapter(session: session)
        case .claude:
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

    /// The quota source for an account. Always `nil`: no real source exists yet.
    ///
    /// This used to hand back `FixtureRateWindowSource` for any account carrying a
    /// quota credential reference. The fixture invents figures — 62% and 31% — and
    /// nothing downstream distinguishes an invented figure from a measured one, so
    /// that path wrote fabricated numbers into the ledger and rendered them as
    /// fact. The only thing keeping a user away from it was that no screen sets
    /// `quotaCredentialReference`.
    ///
    /// The access-route spike has since landed (`docs/superpowers/specs/
    /// 2026-07-28-quota-access-routes.md`) and found no route to short-term rate
    /// windows for any provider, so there is nothing this could resolve to. It
    /// returns `nil` until a source that measures something real exists. The
    /// fixture stays in the target for tests, which inject it directly through
    /// `SyncCoordinator(rateWindowSourceProvider:)`.
    func rateWindowSource(for account: Account) -> (any RateWindowSource)? {
        nil
    }
}
