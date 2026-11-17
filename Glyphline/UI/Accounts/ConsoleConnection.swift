import Foundation

/// Shows the Console sign-in for one account and reports what came of it.
protocol ConsoleSignInPresenting {
    @MainActor func presentConsoleSignIn(for account: Account) async -> ConsoleSignInOutcome
}

enum ConsoleSignInOutcome: Equatable, Sendable {
    case connected([ConsoleOrganization])
    case failed(RateWindowSourceError)
    case cancelled
}

/// Connects an account to the Claude Console and disconnects it again.
///
/// Like `AddAccountFlow`, it lives outside the view because the order matters
/// and a `View` cannot be tested.
///
/// **A failed or cancelled connect removes nothing.** The Console sign-in shares
/// the account's data store with its claude.ai session; cleaning up after a
/// failure would put at risk the sign-in the account already works with.
///
/// **Disconnect clears the ledger first, then the session.** Should the session
/// removal not take, the account still stops showing credit — the reverse order
/// could leave an account polling a Console it can no longer reach.
@MainActor
struct ConsoleConnection {
    enum Outcome: Equatable {
        case done
        case failed(String)
    }

    static let cancelledMessage = "Connecting the Console was cancelled. Nothing was changed."
    static let saveFailedMessage = "Could not save the Console connection."

    let ledgerStore: LedgerStore
    let signIn: any ConsoleSignInPresenting
    let sessions: any ConsoleSessionRemoving

    static func isEligible(_ account: Account) -> Bool {
        account.providerID == .claude
            && AccountCredentialReference.source(of: account.credentialReference) == .claudeWebSession
    }

    func connect(_ account: Account) async -> Outcome {
        switch await signIn.presentConsoleSignIn(for: account) {
        case .connected(let organizations):
            // Signed in, but no organisation whose billing can be read: nothing
            // to connect, and an empty list would read as "not connected" anyway.
            guard !organizations.isEmpty else {
                return .failed(RateWindowSourceError.notAvailable.message)
            }
            do {
                try ledgerStore.setConsoleOrganizations(accountID: account.id, organizations)
            } catch {
                return .failed(Self.saveFailedMessage)
            }
            return .done
        case .failed(let error):
            return .failed(error.message)
        case .cancelled:
            return .failed(Self.cancelledMessage)
        }
    }

    func disconnect(_ account: Account) async -> Outcome {
        do {
            try ledgerStore.setConsoleOrganizations(accountID: account.id, [])
        } catch {
            return .failed(Self.saveFailedMessage)
        }
        await sessions.removeConsoleSession(for: account.id)
        return .done
    }
}
