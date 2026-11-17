import Foundation

/// Decides what a document body coming out of the web view actually is.
///
/// Pure function over a string and a status code so the whole decision layer is
/// testable without WebKit. Never includes any part of the body in an error —
/// the body can contain a live session.
enum ClaudeWebResponseClassifier {
    private static let challengeMarkers = ["just a moment", "cf-challenge", "cf-browser-verification", "checking your browser"]

    /// Classifies a usage response.
    static func classify(body: String, statusCode: Int?) -> Result<Data, RateWindowSourceError> {
        classify(body: body, statusCode: statusCode) {
            (try? ClaudeUsageResponse.decode($0)) != nil
        }
    }

    /// Classifies an organisations response.
    ///
    /// Everything up to the shape check is identical — a challenge, a 401 and a
    /// sign-in document at 200 mean the same thing on either route. Only the
    /// final "is this the payload I asked for" differs, and that difference stays
    /// here rather than at the call site: the organisations body is a JSON
    /// *array*, which the usage decoder rejects, so classifying it with
    /// `classify(body:statusCode:)` would report `unexpectedResponseShape` for a
    /// perfectly good response.
    static func classifyOrganizations(body: String, statusCode: Int?) -> Result<Data, RateWindowSourceError> {
        classify(body: body, statusCode: statusCode) {
            (try? ClaudeOrganizationsResponse.decode($0)) != nil
        }
    }

    /// Classifies a Console organisations response. An empty list of API orgs
    /// is still a readable shape; whether one exists is judged elsewhere.
    static func classifyConsoleOrganizations(body: String, statusCode: Int?) -> Result<Data, RateWindowSourceError> {
        classify(body: body, statusCode: statusCode, forbiddenMeansSessionExpired: consoleSessionInvalid) {
            (try? ConsoleOrganizationsResponse.apiOrganizations(from: $0)) != nil
        }
    }

    /// Classifies a Console prepaid-credits response.
    static func classifyConsoleCredits(body: String, statusCode: Int?) -> Result<Data, RateWindowSourceError> {
        classify(body: body, statusCode: statusCode, forbiddenMeansSessionExpired: consoleSessionInvalid) {
            (try? ConsoleCreditsResponse.decode($0)) != nil
        }
    }

    /// Classifies a Console current-spend response.
    static func classifyConsoleSpend(body: String, statusCode: Int?) -> Result<Data, RateWindowSourceError> {
        classify(body: body, statusCode: statusCode, forbiddenMeansSessionExpired: consoleSessionInvalid) {
            (try? ConsoleCurrentSpendResponse.decode($0)) != nil
        }
    }

    /// The Console answers 403 both for a dead session and for a member
    /// without billing rights. Only the former names `account_session_invalid`;
    /// the latter must not read as an expired session.
    private static func consoleSessionInvalid(_ body: String) -> Bool {
        body.contains("account_session_invalid")
    }

    /// The shared judgement. `isExpectedShape` is supplied by this type only, so
    /// no caller can weaken what counts as a readable response.
    /// `forbiddenMeansSessionExpired` decides whether a 403 is a dead session
    /// (`.sessionExpired`) or a missing permission (`.notAvailable`).
    private static func classify(
        body: String,
        statusCode: Int?,
        forbiddenMeansSessionExpired: (String) -> Bool = { _ in true },
        isExpectedShape: (Data) -> Bool
    ) -> Result<Data, RateWindowSourceError> {
        let lowered = body.lowercased()

        if challengeMarkers.contains(where: lowered.contains) {
            return .failure(.transportFailure)
        }

        switch statusCode {
        case 401:
            return .failure(.sessionExpired)
        case 403:
            return .failure(forbiddenMeansSessionExpired(body) ? .sessionExpired : .notAvailable)
        case .none:
            return .failure(.transportFailure)
        case .some(let code) where !(200..<300).contains(code):
            return .failure(.transportFailure)
        default:
            break
        }

        // A gone session answers 200 with the sign-in document.
        if lowered.contains("<!doctype html") || lowered.hasPrefix("<html") {
            return .failure(.sessionExpired)
        }

        let data = Data(body.utf8)
        guard isExpectedShape(data) else {
            return .failure(.unexpectedResponseShape)
        }
        return .success(data)
    }
}
