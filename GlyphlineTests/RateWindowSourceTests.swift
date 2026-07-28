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
        XCTAssertNotNil(result.message)
    }

    func testEachFailureKindHasItsOwnMessage() {
        let messages = [
            RateWindowSourceError.notConfigured.message,
            RateWindowSourceError.credentialRejected(statusCode: 401).message,
            RateWindowSourceError.transportFailure.message,
            RateWindowSourceError.unreadableResponse.message,
        ]

        XCTAssertEqual(Set(messages).count, 4, "\"error\" does not tell the user what to do")
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
    }

    func testNoFailureMessageLeaksACredential() {
        // The status code may travel; the token never may.
        let message = RateWindowSourceError.credentialRejected(statusCode: 403).message
        XCTAssertFalse(message.lowercased().contains("bearer"))
        XCTAssertFalse(message.lowercased().contains("sk-"))
    }
}
