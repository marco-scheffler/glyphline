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
    /// `classify(body:statusCode:)` would report `unreadableResponse` for a
    /// perfectly good response.
    static func classifyOrganizations(body: String, statusCode: Int?) -> Result<Data, RateWindowSourceError> {
        classify(body: body, statusCode: statusCode) {
            (try? ClaudeOrganizationsResponse.decode($0)) != nil
        }
    }

    /// The shared judgement. `isExpectedShape` is supplied by this type only, so
    /// no caller can weaken what counts as a readable response.
    private static func classify(
        body: String,
        statusCode: Int?,
        isExpectedShape: (Data) -> Bool
    ) -> Result<Data, RateWindowSourceError> {
        let lowered = body.lowercased()

        if challengeMarkers.contains(where: lowered.contains) {
            return .failure(.transportFailure)
        }

        switch statusCode {
        case 401, 403:
            return .failure(.sessionExpired)
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
            return .failure(.unreadableResponse)
        }
        return .success(data)
    }
}
