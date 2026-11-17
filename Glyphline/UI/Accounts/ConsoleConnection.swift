import Foundation

/// Shows the Console sign-in for one account and reports what came of it.
protocol ConsoleSignInPresenting {
    @MainActor func presentConsoleSignIn(for account: Account) async -> ConsoleSignInOutcome
}

/// The real Console presenter: the same window, pointed at platform.claude.com,
/// in the account's own data store.
@MainActor
struct ConsoleSignInWindowPresenter: ConsoleSignInPresenting {
    var sessionStore = ClaudeWebSessionStore()

    func presentConsoleSignIn(for account: Account) async -> ConsoleSignInOutcome {
        await ClaudeSignInWindow(account: account, sessionStore: sessionStore, target: .console).presentConsole()
    }
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

    static var cancelledMessage: String {
        String(
            localized: "Connecting the Console was cancelled. Nothing was changed.",
            comment: "Shown when the user closed the Claude Console sign-in window before it finished."
        )
    }

    static var saveFailedMessage: String {
        String(
            localized: "Could not save the Console connection.",
            comment: "Shown when connecting or disconnecting the Claude Console could not be written to the app's database."
        )
    }

    /// Signed in, but no organisation whose credit can be read. Shared with the
    /// sign-in window, so both say it the same way.
    static var noOrganizationMessage: String {
        String(
            localized: "This login has no Claude Console organisation whose credit can be read.",
            comment: "Shown when the Claude Console sign-in worked but the login has no API organisation whose prepaid credit the user may read."
        )
    }

    let ledgerStore: LedgerStore
    let signIn: any ConsoleSignInPresenting
    let sessions: any ConsoleSessionRemoving

    func connect(_ account: Account) async -> Outcome {
        switch await signIn.presentConsoleSignIn(for: account) {
        case .connected(let organizations):
            // Signed in, but no organisation whose billing can be read: nothing
            // to connect, and an empty list would read as "not connected" anyway.
            guard !organizations.isEmpty else {
                return .failed(Self.noOrganizationMessage)
            }
            do {
                try ledgerStore.setConsoleOrganizations(accountID: account.id, organizations)
            } catch {
                return .failed(Self.saveFailedMessage)
            }
            return .done
        case .failed(.notAvailable):
            return .failed(Self.noOrganizationMessage)
        case .failed(let error):
            return .failed(error.consoleMessage)
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
