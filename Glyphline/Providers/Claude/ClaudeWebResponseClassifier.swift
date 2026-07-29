import Foundation

/// Decides what a document body coming out of the web view actually is.
///
/// Pure function over a string and a status code so the whole decision layer is
/// testable without WebKit. Never includes any part of the body in an error —
/// the body can contain a live session.
enum ClaudeWebResponseClassifier {
    private static let challengeMarkers = ["just a moment", "cf-challenge", "cf-browser-verification", "checking your browser"]

    static func classify(body: String, statusCode: Int?) -> Result<Data, RateWindowSourceError> {
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
        guard (try? ClaudeUsageResponse.decode(data)) != nil else {
            return .failure(.unreadableResponse)
        }
        return .success(data)
    }
}
