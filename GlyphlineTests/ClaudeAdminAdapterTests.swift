import XCTest
@testable import Glyphline

final class ClaudeAdminAdapterTests: XCTestCase {
    private let account = Account(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        providerID: .claude,
        displayName: "Org",
        credentialReference: "keychain://glyphline/org",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
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

    private func makeAdapter() -> ClaudeUsageAdapter {
        ClaudeUsageAdapter(
            mode: .adminAPI,
            session: StubURLProtocol.makeSession(),
            now: { Date(timeIntervalSince1970: 1_783_000_000) }
        )
    }

    func testUsagePagesAreFollowedAndTokenClassesMapped() async throws {
        let usagePath = "/v1/organizations/usage_report/messages"
        StubURLProtocol.enqueue(path: usagePath, body: try fixture("claude-usage-report"))
        StubURLProtocol.enqueue(path: usagePath, body: try fixture("claude-usage-report-page2"))
        StubURLProtocol.enqueue(path: "/v1/organizations/cost_report", body: try fixture("claude-cost-report"))

        let result = try await makeAdapter().sync(account: account, secret: "sk-ant-admin-test")

        XCTAssertEqual(result.usageSnapshots.count, 2)
        XCTAssertEqual(result.capabilities.dataQuality, .exact)

        let opus = try XCTUnwrap(result.usageSnapshots.first { $0.model == "claude-opus-4-8" })
        XCTAssertEqual(opus.inputTokens, 1500)
        XCTAssertEqual(opus.cacheCreationTokens, 1500) // 500 + 1000
        XCTAssertEqual(opus.cacheReadTokens, 200)
        XCTAssertEqual(opus.outputTokens, 500)
        XCTAssertNil(opus.requests, "the Anthropic usage report reports no request count")
    }

    func testCostAmountIsReadAsCents() async throws {
        StubURLProtocol.enqueue(
            path: "/v1/organizations/usage_report/messages",
            body: try fixture("claude-usage-report-page2")
        )
        StubURLProtocol.enqueue(path: "/v1/organizations/cost_report", body: try fixture("claude-cost-report"))

        let result = try await makeAdapter().sync(account: account, secret: "sk-ant-admin-test")

        // "123.45" cents is $1.2345, which is 1_234_500 micros — not 123_450_000.
        XCTAssertEqual(result.costSnapshots.first?.amountMicros, 1_234_500)
        XCTAssertEqual(result.costSnapshots.first?.currency, "USD")
    }

    func testAdminKeyGoesInApiKeyHeaderAndOtherSecretsUseBearer() async throws {
        var adminRequest: URLRequest?
        var bearerRequest: URLRequest?

        adminRequest = try ClaudeUsageAdapter.makeUsageRequest(
            secret: "sk-ant-admin-abc",
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 86_400),
            page: nil
        )
        bearerRequest = try ClaudeUsageAdapter.makeUsageRequest(
            secret: "oauth-token",
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 86_400),
            page: nil
        )

        XCTAssertEqual(adminRequest?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-admin-abc")
        XCTAssertNil(adminRequest?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(bearerRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
        XCTAssertNil(bearerRequest?.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(adminRequest?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testUnauthorizedBecomesUnavailableRatherThanAnError() async throws {
        StubURLProtocol.enqueue(
            path: "/v1/organizations/usage_report/messages",
            statusCode: 401,
            body: Data()
        )

        let result = try await makeAdapter().sync(account: account, secret: "not-an-admin-key")

        XCTAssertEqual(result.capabilities.dataQuality, .unavailable)
        XCTAssertTrue(result.usageSnapshots.isEmpty)
        XCTAssertNotNil(result.capabilities.message)
    }

    /// The Admin API is queried in UTC with `bucket_width=1d`, so the periods and
    /// buckets derived from its answers must be UTC too. A local calendar would
    /// label them with the wrong day for any user off UTC.
    func testPeriodAndBucketBoundariesAreUTCRegardlessOfLocalTimeZone() async throws {
        StubURLProtocol.enqueue(
            path: "/v1/organizations/usage_report/messages",
            body: try fixture("claude-usage-report-page2")
        )
        StubURLProtocol.enqueue(path: "/v1/organizations/cost_report", body: try fixture("claude-cost-report"))

        // A calendar pinned well away from UTC; the adapter must override it.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati")) // UTC+14
        let adapter = ClaudeUsageAdapter(
            mode: .adminAPI,
            session: StubURLProtocol.makeSession(),
            now: { Date(timeIntervalSince1970: 1_783_000_000) }, // 2026-07-02T13:46:40Z
            calendar: local
        )

        let result = try await adapter.sync(account: account, secret: "sk-ant-admin-test")

        XCTAssertEqual(
            result.billingPeriod?.startsAt,
            Date(timeIntervalSince1970: 1_782_864_000), // 2026-07-01T00:00:00Z
            "the period starts at the UTC month boundary, not the local one"
        )
        XCTAssertEqual(
            result.usageSnapshots.first?.bucketStart,
            Date(timeIntervalSince1970: 1_782_950_400), // 2026-07-02T00:00:00Z
            "the bucket keeps the UTC instant the API reported"
        )
    }

    func testDailyBucketLimitIsExplicit() throws {
        let request = try ClaudeUsageAdapter.makeUsageRequest(
            secret: "sk-ant-admin-abc",
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 86_400),
            page: nil
        )
        let query = try XCTUnwrap(request.url?.query)

        XCTAssertTrue(query.contains("limit=31"), "the daily default 7 buckets paginate silently")
        XCTAssertTrue(query.contains("bucket_width=1d"))
    }
}
