import Foundation
import WebKit

/// Maps an account to its own persistent web session.
///
/// The only place that knows separate sessions exist. Everything else sees a
/// data store and never a cookie: the session key lives in WebKit's storage and
/// reaches neither the Keychain, nor the ledger, nor any message.
///
/// The identifier is derived from the account id rather than generated, so a
/// relaunch resolves to the same store and the user does not sign in again.
struct ClaudeWebSessionStore: Sendable {
    func dataStoreIdentifier(for accountID: UUID) -> UUID {
        accountID
    }

    @MainActor
    func dataStore(for accountID: UUID) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: dataStoreIdentifier(for: accountID))
    }
}
