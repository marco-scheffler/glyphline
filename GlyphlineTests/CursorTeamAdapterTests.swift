import XCTest
@testable import Glyphline

final class CursorTeamAdapterTests: XCTestCase {
    private let account = Account(
        id: UUID(uuidString: "66666666-7777-8888-9999-000000000000")!,
        providerID: .cursor,
        displayName: "Team",
        credentialReference: "keychain://glyphline/team",
        createdAt: Date(timeIntervalSince1970: 1_780_000_000),
        isEnabled: true
    )

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeAdapter() -> CursorUsageAdapter {
        CursorUsageAdapter(
            mode: .teamAPI,
            session: StubURLProtocol.makeSession(),
            now: { Date(timeIntervalSince1970: 1_783_200_000) }
        )
    }

    func testEventPagesAreFollowedAndAggregatedByDayAndModel() async throws {
        let eventsPath = "/teams/filtered-usage-events"
        StubURLProtocol.enqueue(path: eventsPath, body: try fixture("cursor-usage-events"))
        StubURLProtocol.enqueue(path: eventsPath, body: try fixture("cursor-usage-events-page2"))
        StubURLProtocol.enqueue(path: "/teams/spend", body: try fixture("cursor-spend"))

        let result = try await makeAdapter().sync(account: account, secret: "key_abc")

        XCTAssertEqual(result.capabilities.dataQuality, .exact)

        let opus = try XCTUnwrap(result.usageSnapshots.first { $0.model == "claude-opus-4-8" })
        XCTAssertEqual(opus.inputTokens, 110)
        XCTAssertEqual(opus.outputTokens, 220)
        XCTAssertEqual(opus.cacheCreationTokens, 330)
        XCTAssertEqual(opus.cacheReadTokens, 440)
        XCTAssertEqual(opus.requests, 2, "two events rolled into one daily bucket")
    }

    func testChargedCentsBecomeMicros() async throws {
        StubURLProtocol.enqueue(path: "/teams/filtered-usage-events", body: try fixture("cursor-usage-events-page2"))
        StubURLProtocol.enqueue(path: "/teams/spend", body: try fixture("cursor-spend"))

        let result = try await makeAdapter().sync(account: account, secret: "key_abc")

        // 4 cents is $0.04, which is 40_000 micros — not 4_000_000.
        XCTAssertEqual(result.costSnapshots.first?.amountMicros, 40_000)
    }

    func testSubscriptionCycleStartBecomesTheBillingPeriod() async throws {
        StubURLProtocol.enqueue(path: "/teams/filtered-usage-events", body: try fixture("cursor-usage-events-page2"))
        StubURLProtocol.enqueue(path: "/teams/spend", body: try fixture("cursor-spend"))

        let result = try await makeAdapter().sync(account: account, secret: "key_abc")

        XCTAssertEqual(
            result.billingPeriod?.startsAt,
            Date(timeIntervalSince1970: 1_782_950_400)
        )
        XCTAssertNotNil(result.billingPeriod?.resetAt)
        XCTAssertTrue(result.capabilities.supportsResetDate)
    }

    func testBasicAuthUsesTheKeyAsUsernameWithEmptyPassword() throws {
        let request = try CursorUsageAdapter.makeEventsRequest(
            secret: "key_abc",
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 86_400),
            page: 1
        )

        let expected = "Basic " + Data("key_abc:".utf8).base64EncodedString()
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expected)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testUnauthorizedBecomesUnavailable() async throws {
        StubURLProtocol.enqueue(path: "/teams/filtered-usage-events", statusCode: 403, body: Data())

        let result = try await makeAdapter().sync(account: account, secret: "not-a-team-key")

        XCTAssertEqual(result.capabilities.dataQuality, .unavailable)
        XCTAssertTrue(result.usageSnapshots.isEmpty)
    }
}
