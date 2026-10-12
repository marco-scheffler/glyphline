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
/// and a `View` cannot be tested: whether an account is written at all, and what
/// is cleaned up when it is not.
///
/// Only a Claude subscription can be added. The admin-key and local-log sources
/// and the OpenAI and Cursor providers lost the adapters that read them in
/// `c1d5ccf`, so an account added with any of them would sit in the list showing
/// nothing. `AccountSource` keeps all three cases because accounts written before
/// that still have to be deleted cleanly.
@MainActor
struct AddAccountFlow {
    enum Outcome: Equatable {
        case saved
        case failed(String)
    }

    static let signInCancelledMessage = "Sign-in was cancelled. Nothing was saved."
    static let saveFailedMessage = "Could not save account."

    let ledgerStore: LedgerStore
    let signIn: any ClaudeSignInPresenting
    /// Cleans up after a sign-in that produced no account. See `discardSession`.
    let webSessions: any WebSessionRemoving

    func save(displayName: String, isEnabled: Bool) async -> Outcome {
        let accountID = UUID()
        var account = Account(
            id: accountID,
            providerID: .claude,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialReference: AccountCredentialReference.make(accountID: accountID, source: .claudeWebSession),
            createdAt: Date(),
            isEnabled: isEnabled
        )

        // Sign in first, write second. An account persisted without an
        // organisation id resolves to no quota source at all, so it would sit in
        // the list showing nothing, forever, with no way to complete it.
        //
        // The account handed to the window is the same one that gets persisted:
        // its id is what `ClaudeWebSessionStore` derives the data store identifier
        // from, so the session established here is the session the steady state
        // will find.
        switch await signIn.presentSignIn(for: account) {
        case .signedIn(let organizationID) where !organizationID.isEmpty:
            account.claudeOrganizationID = organizationID
        case .signedIn:
            // The window does not produce this, and if it ever did the account
            // would be as useless as one that never signed in.
            await discardSession(for: account)
            return .failed(RateWindowSourceError.notAvailable.message)
        case .failed(let error):
            // The error already carries the sentence for this failure. Writing a
            // second one here is a second place for the wording to drift.
            await discardSession(for: account)
            return .failed(error.message)
        case .cancelled:
            await discardSession(for: account)
            return .failed(Self.signInCancelledMessage)
        }

        do {
            try ledgerStore.saveAccount(account)
            return .saved
        } catch {
            await discardSession(for: account)
            return .failed(Self.saveFailedMessage)
        }
    }

    /// Removes the data store the sign-in window created, on every exit that does
    /// not persist the account.
    ///
    /// The window navigates to claude.ai as soon as it opens, so WebKit has
    /// already written a persistent store keyed on this account id by the time any
    /// of these exits is reached. The identifier is *derived* from that id, so once
    /// the id is thrown away — and it is, on every one of these paths, because no
    /// row is written — nothing can enumerate or name the store again. That is
    /// exactly the orphan `DeleteAccountFlow` orders its steps to prevent, and the
    /// worst shape of it is a successful sign-in on a subscription with no quota:
    /// a live session left on disk, unreachable forever.
    ///
    /// `try?`, deliberately. The caller is already being told why nothing was
    /// saved, and replacing that sentence with one about a data store would report
    /// the cleanup instead of the outcome the user asked about.
    private func discardSession(for account: Account) async {
        try? await webSessions.removeSession(for: account.id)
    }
}
