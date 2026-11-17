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

/// Removing an account's web session.
///
/// A seam, because the real thing is a process-wide WebKit call against a
/// directory in the user's Library. A test that used it would create or delete
/// real state on the developer's machine, and its failure path — the one the
/// deletion ordering exists to handle — cannot be provoked at all.
@MainActor
protocol WebSessionRemoving: Sendable {
    func removeSession(for accountID: UUID) async throws
}

extension ClaudeWebSessionStore: WebSessionRemoving {
    /// Removes this account's persistent session, if it has one.
    ///
    /// Most accounts do not: only a web-session account ever signs in, and even
    /// then a store exists only once WebKit has written it. Asking WebKit which
    /// identifiers exist before removing one means "there was nothing to remove"
    /// stays a success — otherwise an account that never signed in could never
    /// be deleted, because its cleanup would fail forever.
    func removeSession(for accountID: UUID) async throws {
        let identifier = dataStoreIdentifier(for: accountID)
        let existing = await WKWebsiteDataStore.allDataStoreIdentifiers
        guard existing.contains(identifier) else { return }
        try await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }
}

/// Removing only an account's Console sign-in, leaving its claude.ai one.
///
/// Both live in the same per-account data store, so this cannot drop the store
/// the way `removeSession` does. A seam for the same reason as
/// `WebSessionRemoving`: the real thing touches WebKit state on disk.
protocol ConsoleSessionRemoving: Sendable {
    @MainActor func removeConsoleSession(for accountID: UUID) async
}

extension ClaudeWebSessionStore: ConsoleSessionRemoving {
    /// Removes the `claude.com` website data from this account's store, if the
    /// account has a store at all. Checking first keeps this from creating a
    /// store — `dataStore(for:)` would — for an account that never signed in.
    @MainActor
    func removeConsoleSession(for accountID: UUID) async {
        let identifier = dataStoreIdentifier(for: accountID)
        let existing = await WKWebsiteDataStore.allDataStoreIdentifiers
        guard existing.contains(identifier) else { return }

        let store = dataStore(for: accountID)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let consoleRecords = records.filter { $0.displayName == "claude.com" }
        guard !consoleRecords.isEmpty else { return }
        await store.removeData(ofTypes: types, for: consoleRecords)
    }
}
