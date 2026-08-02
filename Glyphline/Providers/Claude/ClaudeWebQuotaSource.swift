import Foundation
import WebKit

/// The claude.ai routes this feature navigates to.
///
/// Shared with `ClaudeSignInWindow` so the sign-in check and the steady-state
/// fetch cannot drift apart — the sign-in succeeds by performing the same
/// operation the steady state performs.
enum ClaudeWebEndpoints {
    static let signIn = URL(string: "https://claude.ai/")!
    static let organizations = URL(string: "https://claude.ai/api/organizations")!

    /// The organisation id is a uuid, but it arrives from a response rather than
    /// from a constant, so it is escaped before it becomes a path component. `/`
    /// is deliberately not in the allowed set: a value carrying one would
    /// otherwise silently address a different route.
    private static let organizationIDAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    static func usage(organizationID: String) -> URL? {
        guard !organizationID.isEmpty,
              let escaped = organizationID.addingPercentEncoding(withAllowedCharacters: organizationIDAllowed)
        else {
            return nil
        }
        return URL(string: "https://claude.ai/api/organizations/\(escaped)/usage")
    }
}

/// Reads a Claude subscription's rate windows through the user's own logged-in
/// claude.ai session.
///
/// There is no token and no cookie here. The session lives in the account's
/// `WKWebsiteDataStore`; this type asks a web view to navigate, reads the
/// document text, and hands it to `ClaudeWebResponseClassifier`, which owns every
/// judgement about what the response actually is. No part of a body reaches a
/// message.
///
/// `@MainActor` because `WKWebView` is. `RateWindowSource`'s requirement is
/// `async`, so a main-actor witness is fine — the caller hops.
@MainActor
struct ClaudeWebQuotaSource: RateWindowSource {
    var sessionStore: ClaudeWebSessionStore
    var now: @Sendable () -> Date
    /// A view waiting on a Cloudflare challenge waits forever, and
    /// `collectRateWindows` runs accounts sequentially, so one hang blocks the
    /// rest. Exceeding this is a `transportFailure`, not a hang.
    var timeout: Duration

    init(
        sessionStore: ClaudeWebSessionStore = ClaudeWebSessionStore(),
        now: @escaping @Sendable () -> Date = Date.init,
        timeout: Duration = .seconds(30)
    ) {
        self.sessionStore = sessionStore
        self.now = now
        self.timeout = timeout
    }

    func fetchWindows(account: Account, secret: String?) async throws -> RateWindowResult {
        // The organisation id is resolved once at sign-in. Without it there is no
        // usage path to navigate to — which is a thing the user can fix, not a
        // failure, so it is a result rather than a throw.
        guard let organizationID = account.claudeOrganizationID,
              let url = ClaudeWebEndpoints.usage(organizationID: organizationID)
        else {
            return Self.unavailable(.notConfigured)
        }

        let loader = ClaudeWebPageLoader(dataStore: sessionStore.dataStore(for: account.id))
        // Every exit releases the view: success, failure, timeout, cancellation.
        defer { loader.tearDown() }

        let outcome: ClaudeWebPageLoader.Outcome
        do {
            outcome = try await loader.load(url, timeout: timeout)
        } catch is CancellationError {
            // The app is shutting down or the tick was abandoned. Reporting that
            // as "could not reach the provider" would put a failure the user did
            // not have in front of them.
            throw CancellationError()
        } catch let error as RateWindowSourceError {
            return Self.unavailable(error)
        } catch {
            return Self.unavailable(.transportFailure)
        }

        switch ClaudeWebResponseClassifier.classify(body: outcome.body, statusCode: outcome.statusCode) {
        case .failure(let error):
            return Self.unavailable(error)
        case .success(let data):
            // The classifier only returns `.success` for a body it has already
            // decoded, so this cannot fail. It still reports rather than throws,
            // because a decode that started failing silently is exactly the case
            // this feature is built to make visible.
            guard let response = try? ClaudeUsageResponse.decode(data) else {
                return Self.unavailable(.unexpectedResponseShape)
            }

            // A decode that yields no window is a subscription with nothing
            // running right now, not a failure: `dataQuality` stays `.exact` and
            // the panel's own "No quota reported yet." says the rest.
            return RateWindowResult(
                windows: response.rateWindows(observedAt: now()),
                dataQuality: .exact,
                message: nil
            )
        }
    }

    /// Messages come from `RateWindowSourceError` and nowhere else, so no part of
    /// a response body can reach one. The code travels with the message because
    /// the message is translated and cannot be recognised downstream.
    private static func unavailable(_ error: RateWindowSourceError) -> RateWindowResult {
        RateWindowResult(
            windows: [],
            dataQuality: .unavailable,
            message: error.message,
            failureCode: error.code
        )
    }
}
