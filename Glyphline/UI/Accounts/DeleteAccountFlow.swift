import Foundation

/// Removes an account and everything it owns.
///
/// The mirror of `AddAccountFlow`, and it lives outside the view for the same
/// reason: the interesting part is the order, and a `View` cannot be tested.
///
/// **External resources first, ledger last.** Delete the row first and then fail
/// to remove the web session, and a live claude.ai session sits on disk with
/// nothing referencing it — the identifier is derived from the account id, so
/// once the account is gone nothing can ever name that store again. The reverse
/// failure is harmless by comparison: the user sees an account that has to sign
/// in again. So a failed cleanup aborts the deletion and says so, rather than
/// pressing on and leaving a phantom.
///
/// **The web session goes first, ahead of the credential deletes.** It is the
/// resource whose orphaning this whole flow exists to prevent, and it is also the
/// only step that can fail while nothing else has been touched yet. Putting it
/// first makes "Nothing was deleted." true at the one point it is claimed — a
/// web-session account can also hold a quota secret, and deleting that first would
/// have let a session failure report a deletion that had in fact already taken the
/// token. The external-first / ledger-last invariant is unchanged: an account
/// exists ⇒ its resources may exist, never the reverse.
@MainActor
struct DeleteAccountFlow {
    enum Outcome: Equatable {
        case deleted
        case failed(String)
    }

    static let credentialCleanupFailedMessage =
        "Could not remove this account's stored credential. The account was not deleted."
    static let webSessionCleanupFailedMessage =
        "Could not remove this account's claude.ai sign-in. Nothing was deleted."
    static let deleteFailedMessage = "Could not delete account."

    let ledgerStore: LedgerStore
    let credentialStore: any CredentialStore
    let webSessions: any WebSessionRemoving

    func delete(_ account: Account) async -> Outcome {
        let source = AccountCredentialReference.source(of: account.credentialReference)

        if source == .claudeWebSession {
            do {
                try await webSessions.removeSession(for: account.id)
            } catch {
                // The caught error is deliberately not read. It may name a path
                // inside the user's Library; the sentence the user needs does not.
                return .failed(Self.webSessionCleanupFailedMessage)
            }
        }

        do {
            if source == .credential {
                try credentialStore.deleteSecret(for: account.credentialReference)
            }
            // Independent of the cost source: an account can draw cost from a
            // credential-free source and quota from a token.
            if let quotaReference = account.quotaCredentialReference {
                try credentialStore.deleteSecret(for: quotaReference)
            }
        } catch {
            return .failed(Self.credentialCleanupFailedMessage)
        }

        do {
            try ledgerStore.deleteAccount(id: account.id)
        } catch {
            return .failed(Self.deleteFailedMessage)
        }

        return .deleted
    }
}
