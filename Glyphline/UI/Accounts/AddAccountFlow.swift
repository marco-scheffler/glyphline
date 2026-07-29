import Foundation

/// Puts the claude.ai sign-in in front of the user for one account.
///
/// A seam, so the rules around the window can be tested without one. A test that
/// had to present the real thing would put a browser window on the developer's
/// screen and reach claude.ai, which is neither a unit test nor acceptable.
@MainActor
protocol ClaudeSignInPresenting {
    func presentSignIn(for account: Account) async -> ClaudeSignInWindow.Outcome
}

/// The real presenter: one window, one account, one private data store.
@MainActor
struct ClaudeSignInWindowPresenter: ClaudeSignInPresenting {
    var sessionStore = ClaudeWebSessionStore()

    func presentSignIn(for account: Account) async -> ClaudeSignInWindow.Outcome {
        await ClaudeSignInWindow(account: account, sessionStore: sessionStore).present()
    }
}

/// Turns a filled-in Add Account form into a persisted account.
///
/// Lives outside the view because the rules it applies are the interesting part
/// and a `View` cannot be tested: which credential reference an account gets,
/// whether a secret is written, and — for a web session — whether an account is
/// written at all.
@MainActor
struct AddAccountFlow {
    enum Outcome: Equatable {
        case saved
        case failed(String)
    }

    static let signInCancelledMessage = "Sign-in was cancelled. Nothing was saved."
    static let saveFailedMessage = "Could not save account."

    let ledgerStore: LedgerStore
    let credentialStore: any CredentialStore
    let signIn: any ClaudeSignInPresenting

    func save(
        providerID: ProviderID,
        displayName: String,
        source: AccountSource,
        credentialValue: String,
        isEnabled: Bool
    ) async -> Outcome {
        let source = Self.effectiveSource(source, providerID: providerID)
        let accountID = UUID()
        var account = Account(
            id: accountID,
            providerID: providerID,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialReference: AccountCredentialReference.make(accountID: accountID, source: source),
            createdAt: Date(),
            isEnabled: isEnabled
        )

        if source == .claudeWebSession {
            // Sign in first, write second. An account persisted without an
            // organisation id resolves to no quota source at all, so it would sit
            // in the list showing nothing, forever, with no way to complete it.
            //
            // The account handed to the window is the same one that gets
            // persisted: its id is what `ClaudeWebSessionStore` derives the data
            // store identifier from, so the session established here is the
            // session the steady state will find.
            switch await signIn.presentSignIn(for: account) {
            case .signedIn(let organizationID) where !organizationID.isEmpty:
                account.claudeOrganizationID = organizationID
            case .signedIn:
                // The window does not produce this, and if it ever did the account
                // would be as useless as one that never signed in.
                return .failed(RateWindowSourceError.notAvailable.message)
            case .failed(let error):
                // The error already carries the sentence for this failure. Writing
                // a second one here is a second place for the wording to drift.
                return .failed(error.message)
            case .cancelled:
                return .failed(Self.signInCancelledMessage)
            }
        }

        do {
            // Only the credential source has a secret. The other two must not write
            // an empty string standing in for one.
            if source == .credential {
                try credentialStore.save(secret: credentialValue, for: account.credentialReference)
            }

            do {
                try ledgerStore.saveAccount(account)
            } catch {
                if source == .credential {
                    try? credentialStore.deleteSecret(for: account.credentialReference)
                }
                throw error
            }

            return .saved
        } catch {
            return .failed(Self.saveFailedMessage)
        }
    }

    /// The local source and the web session are Claude's alone. A selection left
    /// over from a provider switch must not decide anything for another provider —
    /// least of all open a claude.ai window for an account that is not Claude.
    private static func effectiveSource(_ source: AccountSource, providerID: ProviderID) -> AccountSource {
        providerID == .claude ? source : .credential
    }
}
