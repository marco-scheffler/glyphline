import Foundation

struct RateWindowResult: Codable, Equatable, Sendable {
    var windows: [RateWindow]
    var dataQuality: DataQuality
    var message: String?
}

/// A source of quota windows for one account.
///
/// Deliberately separate from `ProviderAdapter`: a Claude Max account draws cost
/// from local logs with no credential at all and quota from a token, so one
/// account needs two independent identities. Folding this into `ProviderAdapter`
/// would mean reworking three functioning adapters so one of them can carry two.
///
/// No source throws for "I cannot do this" — that is a result with
/// `.unavailable` and a reason that reaches the menu.
protocol RateWindowSource: Sendable {
    func fetchWindows(account: Account, secret: String?) async throws -> RateWindowResult
}

/// The ways a quota fetch fails, each with its own message, because "error" does
/// not tell the user what to do.
///
/// `notConfigured` and `notAvailable` are deliberately separate. One invites the
/// user to act, the other tells them there is nothing to act on — and the access
/// spike found that for Claude rate windows no route exists at any price, so
/// telling that user to "set one up" sends them after something that is not
/// there. `notConfigured` is kept for the providers where a route does exist and
/// simply has not been configured yet, which is where the spike left Cursor.
///
/// Carries a status code but never a header, a token, or a response body.
enum RateWindowSourceError: Error, Equatable, Sendable {
    /// A route exists for this provider, but this account has not been given one.
    case notConfigured
    /// No route to quota exists for this subscription at all. Not the user's to fix.
    case notAvailable
    /// 401 or 403 — the case the user can fix.
    case credentialRejected(statusCode: Int)
    /// Network or provider unreachable. Transient.
    case transportFailure
    /// The page could not be read at all — the document body never came back as
    /// text, the script evaluation threw, or the response could not be displayed.
    /// Nothing was seen, so nothing can be said about its shape.
    case unreadablePage
    /// The page was read, but it was not what we expected. During sign-in this
    /// almost always means the sign-in had not completed yet; in steady state it
    /// means the endpoint changed, which is the case that would otherwise cause
    /// silent misreporting.
    case unexpectedResponseShape
    /// The web session is no longer valid. Unlike `credentialRejected` there is
    /// no stored token to replace — the user signs in again in a browser.
    case sessionExpired

    var message: String {
        switch self {
        case .notConfigured:
            "No quota source is set up for this subscription."
        case .notAvailable:
            "Quota reporting is not available for this subscription."
        case .credentialRejected:
            "The stored quota token was rejected. Re-authorise this subscription."
        case .transportFailure:
            "Could not reach the provider. This is usually temporary."
        case .unreadablePage:
            "Could not read the page claude.ai returned. This is usually temporary."
        case .unexpectedResponseShape:
            "claude.ai did not return the expected data. If you are signing in, make sure you are fully signed in before continuing."
        case .sessionExpired:
            "Your Claude sign-in has expired. Sign in again."
        }
    }
}
