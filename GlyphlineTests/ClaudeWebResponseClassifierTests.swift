import XCTest
@testable import Glyphline

final class ClaudeWebResponseClassifierTests: XCTestCase {
    private func error(_ body: String, _ status: Int?) -> RateWindowSourceError? {
        if case .failure(let error) = ClaudeWebResponseClassifier.classify(body: body, statusCode: status) {
            return error
        }
        return nil
    }

    func testJSONWithTheExpectedShapeSucceeds() {
        let body = #"{"five_hour":{"utilization":4.0,"resets_at":"2026-07-29T10:30:00Z"}}"#
        guard case .success(let data) = ClaudeWebResponseClassifier.classify(body: body, statusCode: 200) else {
            return XCTFail("expected success")
        }
        XCTAssertFalse(data.isEmpty)
    }

    func testAnUnauthorisedStatusIsASessionProblemNotACredentialOne() {
        // The user has no token to re-enter; they have a session to re-establish.
        XCTAssertEqual(error("", 401), .sessionExpired)
        XCTAssertEqual(error("", 403), .sessionExpired)
    }

    func testASignInPageIsASessionProblemEvenWithA200() {
        // The endpoint answers 200 with HTML when the session is gone.
        let body = "<!DOCTYPE html><html><head><title>Sign in</title></head><body></body></html>"
        XCTAssertEqual(error(body, 200), .sessionExpired)
    }

    func testACloudflareChallengeIsTransient() {
        let body = "<html><head><title>Just a moment...</title></head><body>cf-challenge</body></html>"
        XCTAssertEqual(error(body, 403), .transportFailure)
    }

    func testBrokenJSONSaysTheEndpointChanged() {
        XCTAssertEqual(error(#"{"five_hour": "#, 200), .unexpectedResponseShape)
    }

    func testNoStatusAtAllIsTransient() {
        XCTAssertEqual(error("", nil), .transportFailure)
    }

    // MARK: - Organisations

    func testTheOrganisationsArrayClassifiesAsSuccess() {
        // The organisations body is a JSON *array*, which the usage decoder
        // rejects. Classifying it with the usage entry point would call a good
        // response unreadable, so the two shape checks stay distinct.
        let body = #"[{"uuid":"abc","capabilities":["claude_max"]}]"#

        guard case .success(let data) = ClaudeWebResponseClassifier.classifyOrganizations(body: body, statusCode: 200) else {
            return XCTFail("expected success")
        }
        XCTAssertFalse(data.isEmpty)

        guard case .failure(let error) = ClaudeWebResponseClassifier.classify(body: body, statusCode: 200) else {
            return XCTFail("the usage entry point must not accept an array")
        }
        XCTAssertEqual(error, .unexpectedResponseShape)
    }

    func testTheOrganisationsRouteMakesTheSameSessionJudgements() {
        let signInPage = "<!DOCTYPE html><html><head><title>Sign in</title></head><body></body></html>"
        let challenge = "<html><head><title>Just a moment...</title></head><body>cf-challenge</body></html>"

        XCTAssertEqual(organizationsError("", 401), .sessionExpired)
        XCTAssertEqual(organizationsError(signInPage, 200), .sessionExpired)
        XCTAssertEqual(organizationsError(challenge, 403), .transportFailure)
        XCTAssertEqual(organizationsError("", nil), .transportFailure)
        XCTAssertEqual(organizationsError(#"{"five_hour":{}}"#, 200), .unexpectedResponseShape)
    }

    func testTheOrganisationsRouteDoesNotLeakTheBodyEither() throws {
        // Not an organisations array, so every status classifies as a failure and
        // the assertions below are real rather than vacuous.
        let secret = #"{"sessionKey":"sk-ant-sid-EXAMPLE"}"#
        for status in [200, 401, 403, 500] {
            let classification = ClaudeWebResponseClassifier.classifyOrganizations(body: secret, statusCode: status)
            guard case .failure(let error) = classification else {
                return XCTFail("expected a failure at \(status)")
            }
            XCTAssertFalse(error.message.contains("sk-ant"))
            XCTAssertFalse(error.message.contains(secret))
        }
    }

    private func organizationsError(_ body: String, _ status: Int?) -> RateWindowSourceError? {
        if case .failure(let error) = ClaudeWebResponseClassifier.classifyOrganizations(body: body, statusCode: status) {
            return error
        }
        return nil
    }

    func testNoClassificationLeaksTheBody() {
        let secret = #"{"sessionKey":"sk-ant-sid-EXAMPLE"}"#
        for status in [200, 401, 403, 500] {
            let message = error(secret, status)?.message ?? ""
            XCTAssertFalse(message.contains("sk-ant"))
            XCTAssertFalse(message.contains(secret))
        }
    }

    // MARK: - Console

    private func fixtureText(_ name: String) throws -> String {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        return try String(contentsOf: XCTUnwrap(url), encoding: .utf8)
    }

    private func failure(_ result: Result<Data, RateWindowSourceError>) -> RateWindowSourceError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    func testConsoleSessionInvalidIsSessionExpired() {
        let body = #"{"type":"error","error":{"type":"permission_error","message":"Invalid authorization","details":{"error_visibility":"user_facing","error_code":"account_session_invalid"}},"request_id":"req_x"}"#
        XCTAssertEqual(failure(ClaudeWebResponseClassifier.classifyConsoleOrganizations(body: body, statusCode: 403)), .sessionExpired)
        XCTAssertEqual(failure(ClaudeWebResponseClassifier.classifyConsoleCredits(body: body, statusCode: 403)), .sessionExpired)
        XCTAssertEqual(failure(ClaudeWebResponseClassifier.classifyConsoleSpend(body: body, statusCode: 403)), .sessionExpired)
    }

    func testConsolePermissionDeniedIsNotAvailable() {
        let body = #"{"type":"error","error":{"type":"permission_error","message":"Permission denied."},"code":"permission_denied"}"#
        XCTAssertEqual(failure(ClaudeWebResponseClassifier.classifyConsoleOrganizations(body: body, statusCode: 403)), .notAvailable)
        XCTAssertEqual(failure(ClaudeWebResponseClassifier.classifyConsoleCredits(body: body, statusCode: 403)), .notAvailable)
        XCTAssertEqual(failure(ClaudeWebResponseClassifier.classifyConsoleSpend(body: body, statusCode: 403)), .notAvailable)
    }

    func testConsole401IsSessionExpired() {
        XCTAssertEqual(failure(ClaudeWebResponseClassifier.classifyConsoleOrganizations(body: "[]", statusCode: 401)), .sessionExpired)
        XCTAssertEqual(failure(ClaudeWebResponseClassifier.classifyConsoleCredits(body: "{}", statusCode: 401)), .sessionExpired)
        XCTAssertEqual(failure(ClaudeWebResponseClassifier.classifyConsoleSpend(body: "{}", statusCode: 401)), .sessionExpired)
    }

    func testConsoleCreditsAcceptTheFixture() throws {
        let body = try fixtureText("console-prepaid-credits")
        guard case .success = ClaudeWebResponseClassifier.classifyConsoleCredits(body: body, statusCode: 200) else {
            return XCTFail("expected success")
        }
    }

    func testConsoleCreditsRejectTheUsageShape() throws {
        let body = try fixtureText("claude-usage")
        XCTAssertEqual(failure(ClaudeWebResponseClassifier.classifyConsoleCredits(body: body, statusCode: 200)), .unexpectedResponseShape)
    }

    func testConsoleEndpointsEscapeTheOrganizationID() throws {
        let credits = try XCTUnwrap(ClaudeWebEndpoints.consoleCredits(organizationID: "a/b"))
        let spend = try XCTUnwrap(ClaudeWebEndpoints.consoleCurrentSpend(organizationID: "a/b"))
        XCTAssertEqual(credits.host, "platform.claude.com")
        XCTAssertEqual(credits.pathComponents, ["/", "api", "organizations", "a/b", "prepaid", "credits"])
        XCTAssertEqual(spend.pathComponents, ["/", "api", "organizations", "a/b", "current_spend"])
        XCTAssertNil(ClaudeWebEndpoints.consoleCredits(organizationID: ""))
        XCTAssertNil(ClaudeWebEndpoints.consoleCurrentSpend(organizationID: ""))
    }
}
