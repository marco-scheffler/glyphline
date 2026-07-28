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

    /// Two syncs on the same day must ask for the same window start, so the
    /// oldest in-window day is always a whole UTC day. A rolling
    /// 30-days-from-now window would hand back a fragment of that day, and the
    /// ledger's replace-upsert would shrink the stored total on the later sync.
    func testEventWindowSnapsToUTCMidnightAndIsStableWithinTheDay() throws {
        let dayStart = Date(timeIntervalSince1970: 1_783_123_200) // 2026-07-04T00:00:00Z
        let noon = Date(timeIntervalSince1970: 1_783_166_400) // 2026-07-04T12:00:00Z
        let evening = Date(timeIntervalSince1970: 1_783_188_000) // 2026-07-04T18:00:00Z
        let expected = Date(timeIntervalSince1970: 1_780_617_600) // 2026-06-05T00:00:00Z

        let adapter = CursorUsageAdapter(mode: .teamAPI, session: StubURLProtocol.makeSession())

        XCTAssertEqual(adapter.eventsWindowStart(for: noon), expected)
        XCTAssertEqual(
            adapter.eventsWindowStart(for: evening),
            adapter.eventsWindowStart(for: noon),
            "a later sync on the same day must not truncate the oldest day's bucket"
        )
        XCTAssertEqual(
            expected.timeIntervalSince1970,
            dayStart.timeIntervalSince1970 - 29 * 86_400,
            "29 days back plus today keeps the request inside the API's 30-day cap"
        )
    }

    func testWindowStartReachesTheWireAsUTCMidnightMillis() throws {
        let adapter = CursorUsageAdapter(mode: .teamAPI, session: StubURLProtocol.makeSession())
        let windowStart = adapter.eventsWindowStart(for: Date(timeIntervalSince1970: 1_783_166_400))

        let request = try CursorUsageAdapter.makeEventsRequest(
            secret: "key_abc",
            start: windowStart,
            end: Date(timeIntervalSince1970: 1_783_166_400),
            page: 1
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["startDate"] as? Int, 1_780_617_600_000)
    }

    /// The spend endpoint is secondary. Losing it must cost the reset date only,
    /// never the usage that was already fetched successfully.
    func testFailedSpendCallKeepsUsageAndDropsOnlyTheResetDate() async throws {
        StubURLProtocol.enqueue(path: "/teams/filtered-usage-events", body: try fixture("cursor-usage-events-page2"))
        StubURLProtocol.enqueue(path: "/teams/spend", statusCode: 500, body: Data())

        let result = try await makeAdapter().sync(account: account, secret: "key_abc")

        XCTAssertEqual(result.capabilities.dataQuality, .exact)
        XCTAssertFalse(result.usageSnapshots.isEmpty, "usage was fetched successfully and must survive")
        XCTAssertFalse(result.costSnapshots.isEmpty)
        XCTAssertNil(result.billingPeriod)
        XCTAssertFalse(result.capabilities.supportsResetDate)
        XCTAssertTrue(result.capabilities.supportsUsage)
    }

    /// A 500 on the events endpoint is the provider being unwell, not the key being
    /// wrong. It used to take the same branch as a 403 and told the user a team admin
    /// key was required.
    func testAProviderOutageOnTheEventsEndpointIsNotACredentialProblem() async throws {
        StubURLProtocol.enqueue(path: "/teams/filtered-usage-events", statusCode: 500, body: Data())

        do {
            _ = try await makeAdapter().sync(account: account, secret: "key_valid")
            XCTFail("a 500 must surface as a failure, not as a degraded result")
        } catch {
            XCTAssertEqual(error as? CursorUsageAdapterError, .requestFailed(statusCode: 500))
        }
    }

    func testUnauthorizedBecomesUnavailable() async throws {
        StubURLProtocol.enqueue(path: "/teams/filtered-usage-events", statusCode: 403, body: Data())

        let result = try await makeAdapter().sync(account: account, secret: "not-a-team-key")

        XCTAssertEqual(result.capabilities.dataQuality, .unavailable)
        XCTAssertTrue(result.usageSnapshots.isEmpty)
    }
}
