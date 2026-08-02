import Foundation

struct RateWindowResult: Codable, Equatable, Sendable {
    var windows: [RateWindow]
    var dataQuality: DataQuality
    var message: String?
    /// Which failure produced `message`, when a failure produced it.
    ///
    /// Carried beside the message rather than derived from it: the message is
    /// shown to the user and therefore translated, so it cannot also be the
    /// thing the app recognises the failure by.
    var failureCode: RateWindowFailureCode?

    init(
        windows: [RateWindow],
        dataQuality: DataQuality,
        message: String? = nil,
        failureCode: RateWindowFailureCode? = nil
    ) {
        self.windows = windows
        self.dataQuality = dataQuality
        self.message = message
        self.failureCode = failureCode
    }
}

/// A failure's identity, stable across languages.
///
/// Exists so that "is this something the user can fix?" is decided by a value
/// the app controls rather than by the wording of a sentence. The strings are
/// stable because they are persisted in `RateWindowResult` and compared, never
/// shown.
enum RateWindowFailureCode: String, Codable, Equatable, Sendable, CaseIterable {
    case notConfigured
    case notAvailable
    case credentialRejected
    case transportFailure
    case unreadablePage
    case unexpectedResponseShape
    case sessionExpired

    /// The failures that mean the user has something to do.
    ///
    /// Only these two. `notAvailable` is a permanent fact about a subscription
    /// and `notConfigured` a route nobody has asked for, so neither is a task —
    /// and the transient three would put a banner on the dashboard for a Wi-Fi
    /// blip, which is how a banner becomes something people stop reading.
    static let userActionable: Set<RateWindowFailureCode> = [
        .sessionExpired,
        .credentialRejected,
    ]

    var isUserActionable: Bool {
        Self.userActionable.contains(self)
    }
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

    /// What the app recognises this failure by. Never shown, never translated.
    ///
    /// The status code is deliberately not part of it: every code that produces
    /// `credentialRejected` means the same thing to the user.
    var code: RateWindowFailureCode {
        switch self {
        case .notConfigured: .notConfigured
        case .notAvailable: .notAvailable
        case .credentialRejected: .credentialRejected
        case .transportFailure: .transportFailure
        case .unreadablePage: .unreadablePage
        case .unexpectedResponseShape: .unexpectedResponseShape
        case .sessionExpired: .sessionExpired
        }
    }

    /// What the user is told. Translated, and therefore never compared against.
    var message: String {
        switch self {
        case .notConfigured:
            String(
                localized: "No quota source is set up for this subscription.",
                comment: "Quota failure reason: a route to quota exists for this provider, but this account has none."
            )
        case .notAvailable:
            String(
                localized: "Quota reporting is not available for this subscription.",
                comment: "Quota failure reason: no route to quota exists for this subscription at all."
            )
        case .credentialRejected:
            String(
                localized: "The stored quota token was rejected. Re-authorise this subscription.",
                comment: "Quota failure reason: the provider answered 401 or 403 to the stored token."
            )
        case .transportFailure:
            String(
                localized: "Could not reach the provider. This is usually temporary.",
                comment: "Quota failure reason: the provider was unreachable."
            )
        case .unreadablePage:
            String(
                localized: "Could not read the page claude.ai returned. This is usually temporary.",
                comment: "Quota failure reason: the page body never came back as text. claude.ai is a host name, keep it."
            )
        case .unexpectedResponseShape:
            String(
                localized: "claude.ai did not return the expected data. If you are signing in, make sure you are fully signed in before continuing.",
                comment: "Quota failure reason: the page was read but was not the expected shape. claude.ai is a host name, keep it."
            )
        case .sessionExpired:
            String(
                localized: "Your Claude sign-in has expired. Sign in again.",
                comment: "Quota failure reason: the web session is no longer valid and there is no stored token to replace."
            )
        }
    }
}
