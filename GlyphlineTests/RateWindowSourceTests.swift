import XCTest
@testable import Glyphline

final class RateWindowSourceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            providerID: .claude,
            displayName: "Max #1",
            credentialReference: "local-source://x",
            createdAt: now,
            isEnabled: true
        )
    }

    func testTheFixtureSourceReportsBothWindowsAsPartial() async throws {
        let source = FixtureRateWindowSource(now: { [now] in now })
        let result = try await source.fetchWindows(account: makeAccount(), secret: nil)

        XCTAssertEqual(result.dataQuality, .partial)
        XCTAssertEqual(Set(result.windows.map(\.kind)), [.rollingFiveHours, .weekly])
        XCTAssertTrue(result.windows.allSatisfy { $0.observedAt == self.now })
        XCTAssertTrue(result.windows.allSatisfy { $0.resetAt > self.now })
    }

    func testTheFixtureSourceCanReportNoSourceConfigured() async throws {
        let source = FixtureRateWindowSource(now: { [now] in now }, behaviour: .unavailable)
        let result = try await source.fetchWindows(account: makeAccount(), secret: nil)

        XCTAssertEqual(result.dataQuality, .unavailable)
        XCTAssertTrue(result.windows.isEmpty)
        // Pinned against the enum rather than a duplicated literal: two copies of
        // the same user-facing sentence drift, and the fixture's copy did.
        XCTAssertEqual(result.message, RateWindowSourceError.notAvailable.message)
    }

    func testEachFailureKindHasItsOwnMessage() {
        let messages = [
            RateWindowSourceError.notConfigured.message,
            RateWindowSourceError.notAvailable.message,
            RateWindowSourceError.credentialRejected(statusCode: 401).message,
            RateWindowSourceError.transportFailure.message,
            RateWindowSourceError.unreadableResponse.message,
        ]

        XCTAssertEqual(Set(messages).count, 5, "\"error\" does not tell the user what to do")
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
    }

    /// The two are not interchangeable. `notConfigured` invites the user to act;
    /// `notAvailable` tells them there is nothing to act on. The spike found no
    /// route to Claude rate windows at any price, so offering "set one up" there
    /// sends the user after something that does not exist.
    func testNotAvailableDoesNotInviteTheUserToSetSomethingUp() {
        let message = RateWindowSourceError.notAvailable.message

        XCTAssertTrue(message.localizedCaseInsensitiveContains("not available"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("set up"))
        XCTAssertNotEqual(message, RateWindowSourceError.notConfigured.message)
    }

    func testNoFailureMessageLeaksACredential() {
        // The status code may travel; the token never may.
        let message = RateWindowSourceError.credentialRejected(statusCode: 403).message
        XCTAssertFalse(message.lowercased().contains("bearer"))
        XCTAssertFalse(message.lowercased().contains("sk-"))
    }
}
