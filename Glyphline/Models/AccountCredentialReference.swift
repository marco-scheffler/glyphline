import Foundation

/// Where one account's data comes from.
///
/// Three answers, not two: a Claude Max subscription read through the user's own
/// claude.ai session has no secret at all *and* no local logs, so it is neither of
/// the shapes that existed before. Modelling it as a second `Bool` alongside
/// "uses local source" would allow two states that mean nothing.
enum AccountSource: Hashable, Sendable, CaseIterable {
    /// A secret the user supplied. Stored in the Keychain, referenced by pointer.
    case credential
    /// A credential-free source on this Mac — the Claude Code logs.
    case localLogs
    /// The user's own claude.ai session, held by WebKit in this account's private
    /// data store. There is no secret for the app to hold, and deliberately so.
    case claudeWebSession
}

/// Builds the credential reference stored on an account.
///
/// The reference is a pointer, never a secret: the Keychain form names the
/// account whose secret to look up, and the other two name no secret at all.
///
/// The reference is also the signal the adapter registry reads to choose between
/// a credentialed API, a local credential-free source, and a web session. The
/// three schemes must stay distinguishable by prefix: a web session that looked
/// like a local source would send every subscription to the same
/// `~/.claude/projects`, so one Mac's costs would be reported once per account.
enum AccountCredentialReference {
    static func make(accountID: UUID, source: AccountSource) -> String {
        switch source {
        case .credential:
            "keychain://glyphline/\(accountID.uuidString)"
        case .localLogs:
            "\(ProviderAdapterRegistry.localSourceScheme)\(accountID.uuidString)"
        case .claudeWebSession:
            "\(ProviderAdapterRegistry.webSessionScheme)\(accountID.uuidString)"
        }
    }

    /// Reads back the source a reference was built for.
    ///
    /// The exact inverse of `make`, and it has to stay that way: deletion decides
    /// from this whether there is a Keychain entry to remove and a web session to
    /// tear down. A reference that reads back as the wrong source either leaves a
    /// live session on disk or fails a deletion that should have succeeded.
    static func source(of reference: String) -> AccountSource {
        if reference.hasPrefix(ProviderAdapterRegistry.webSessionScheme) {
            return .claudeWebSession
        }
        if reference.hasPrefix(ProviderAdapterRegistry.localSourceScheme) {
            return .localLogs
        }
        return .credential
    }
}
