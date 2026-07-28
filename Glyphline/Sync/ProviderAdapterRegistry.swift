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

    /// The quota source for an account, or `nil` when none is configured.
    ///
    /// Until the access-route spike lands, only the fixture source exists, and it
    /// is returned solely for accounts that carry a quota credential reference —
    /// an account without one has no quota source and renders grey.
    func rateWindowSource(for account: Account) -> (any RateWindowSource)? {
        guard account.quotaCredentialReference != nil else { return nil }
        return FixtureRateWindowSource()
    }
}
