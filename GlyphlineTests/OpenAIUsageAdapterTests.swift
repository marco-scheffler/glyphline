import Foundation
import XCTest

@testable import Glyphline

final class OpenAIUsageAdapterTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testDecodesUsageFixtureIncludingPaginationMetadata() throws {
        let data = try XCTUnwrap(Self.fixture(named: "openai-usage"))
        let decoded = try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)

        XCTAssertEqual(decoded.object, "page")
        XCTAssertEqual(decoded.data.count, 1)
        XCTAssertEqual(decoded.data.first?.results.count, 1)
        XCTAssertFalse(decoded.hasMore)
        XCTAssertNil(decoded.nextPage)
    }

    func testDecodesCostsFixtureAndMapsExactMicros() throws {
        let data = try XCTUnwrap(Self.fixture(named: "openai-costs"))
        let decoded = try JSONDecoder().decode(OpenAICostsResponse.self, from: data)
        let accountID = UUID()

        XCTAssertEqual(decoded.object, "page")
        XCTAssertEqual(decoded.data.count, 1)
        XCTAssertEqual(decoded.data.first?.results.count, 1)
        XCTAssertFalse(decoded.hasMore)
        XCTAssertNil(decoded.nextPage)

        let snapshots = OpenAIUsageAdapter().makeCostSnapshots(from: decoded, accountID: accountID)

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.accountID, accountID)
        XCTAssertEqual(snapshots.first?.providerID, .openAI)
        XCTAssertEqual(snapshots.first?.amountMicros, 60_000)
        XCTAssertEqual(snapshots.first?.currency, "usd")
        XCTAssertEqual(snapshots.first?.quality, .exact)
    }

    func testMapsDecodedUsageIntoExactSnapshots() throws {
        let data = try XCTUnwrap(Self.fixture(named: "openai-usage"))
        let decoded = try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)
        let accountID = UUID()

        let snapshots = OpenAIUsageAdapter().makeUsageSnapshots(from: decoded, accountID: accountID)

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.accountID, accountID)
        XCTAssertEqual(snapshots.first?.providerID, .openAI)
        XCTAssertEqual(snapshots.first?.model, "gpt-5.4")
        XCTAssertEqual(snapshots.first?.inputTokens, 1_000)
        XCTAssertEqual(snapshots.first?.outputTokens, 500)
        XCTAssertEqual(snapshots.first?.requests, 3)
        XCTAssertEqual(snapshots.first?.quality, .exact)
    }

    func testSyncFetchesAllUsagePagesAndActualCosts() async throws {
        let account = Self.makeAccount()
        let now = Date(timeIntervalSince1970: 1_800_100_000)
        // No calendar injected: these must exercise the production default. Supplying
        // the correct one here is exactly what hid the local-calendar defect.
        let adapter = OpenAIUsageAdapter(session: Self.makeSession(), now: { now })

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

            switch url.path {
            case "/v1/organization/usage/completions":
                let page = components.queryItems?.first(where: { $0.name == "page" })?.value
                if page == "usage-page-2" {
                    return Self.httpResponse(
                        url: url,
                        json: """
                        {
                          "object": "page",
                          "data": [
                            {
                              "object": "bucket",
                              "start_time": 1800086400,
                              "end_time": 1800172800,
                              "results": [
                                {
                                  "object": "organization.usage.completions.result",
                                  "model": "gpt-5.4-mini",
                                  "input_tokens": 150,
                                  "output_tokens": 75,
                                  "num_model_requests": 2
                                }
                              ]
                            }
                          ],
                          "has_more": false,
                          "next_page": null
                        }
                        """
                    )
                }

                XCTAssertEqual(
                    components.queryItems?.first(where: { $0.name == "group_by" })?.value,
                    "model"
                )

                return Self.httpResponse(
                    url: url,
                    json: """
                    {
                      "object": "page",
                      "data": [
                        {
                          "object": "bucket",
                          "start_time": 1800000000,
                          "end_time": 1800086400,
                          "results": [
                            {
                              "object": "organization.usage.completions.result",
                              "model": "gpt-5.4",
                              "input_tokens": 1000,
                              "output_tokens": 500,
                              "num_model_requests": 3
                            }
                          ]
                        }
                      ],
                      "has_more": true,
                      "next_page": "usage-page-2"
                    }
                    """
                )

            case "/v1/organization/costs":
                return Self.httpResponse(
                    url: url,
                    json: """
                    {
                      "object": "page",
                      "data": [
                        {
                          "object": "bucket",
                          "start_time": 1800000000,
                          "end_time": 1800086400,
                          "results": [
                            {
                              "object": "organization.costs.result",
                              "amount": {
                                "value": 0.06,
                                "currency": "usd"
                              },
                              "line_item": null,
                              "project_id": null,
                              "api_key_id": null,
                              "quantity": null
                            }
                          ]
                        }
                      ],
                      "has_more": false,
                      "next_page": null
                    }
                    """
                )

            default:
                XCTFail("Unexpected path: \(url.path)")
                throw OpenAIUsageAdapterError.invalidRequest
            }
        }

        let result = try await adapter.sync(account: account, secret: "test-secret")
        let requestedPaths = MockURLProtocol.requests.compactMap(\.url?.path)
        let secondUsageRequest = try XCTUnwrap(
            MockURLProtocol.requests.first {
                $0.url?.path == "/v1/organization/usage/completions"
                    && $0.url?.query?.contains("page=usage-page-2") == true
            }
        )

        XCTAssertEqual(
            requestedPaths,
            [
                "/v1/organization/usage/completions",
                "/v1/organization/usage/completions",
                "/v1/organization/costs",
            ]
        )
        XCTAssertEqual(result.capabilities.dataQuality, .exact)
        XCTAssertTrue(result.capabilities.supportsUsage)
        XCTAssertTrue(result.capabilities.supportsActualCost)
        XCTAssertTrue(result.capabilities.supportsModelBreakdown)
        XCTAssertNil(result.capabilities.message)
        XCTAssertEqual(result.usageSnapshots.count, 2)
        XCTAssertEqual(result.costSnapshots.count, 1)
        XCTAssertEqual(result.usageSnapshots.map(\.model), ["gpt-5.4", "gpt-5.4-mini"])
        XCTAssertEqual(result.costSnapshots.first?.amountMicros, 60_000)
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(secondUsageRequest.url), resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "page" })?
                .value,
            "usage-page-2"
        )
    }

    func testSyncTreatsSuccessfulEmptyResponsesAsExactZeroData() async throws {
        let account = Self.makeAccount()
        let now = Date(timeIntervalSince1970: 1_800_100_000)
        // No calendar injected: these must exercise the production default. Supplying
        // the correct one here is exactly what hid the local-calendar defect.
        let adapter = OpenAIUsageAdapter(session: Self.makeSession(), now: { now })

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)

            return Self.httpResponse(
                url: url,
                json: """
                {
                  "object": "page",
                  "data": [],
                  "has_more": false,
                  "next_page": null
                }
                """
            )
        }

        let result = try await adapter.sync(account: account, secret: "test-secret")

        XCTAssertEqual(result.capabilities.dataQuality, .exact)
        XCTAssertTrue(result.capabilities.supportsUsage)
        XCTAssertTrue(result.capabilities.supportsActualCost)
        XCTAssertTrue(result.usageSnapshots.isEmpty)
        XCTAssertTrue(result.costSnapshots.isEmpty)
        XCTAssertNil(result.capabilities.message)
    }

    /// The period the adapter derives becomes the `start_time` it queries with, and
    /// backfill supplies UTC-midnight slices for that same parameter. A local
    /// calendar would make routine sync and backfill key the same real day under two
    /// different bucket boundaries; both rows would survive the unique key and be
    /// summed. The bucket instants the API itself reports must survive untouched.
    func testPeriodAndBucketBoundariesAreUTCRegardlessOfLocalTimeZone() async throws {
        let account = Self.makeAccount()
        // 2026-07-02T13:46:40Z. In UTC+14 this is already 2026-07-03 local, and the
        // local month began at 2026-06-30T10:00:00Z.
        let now = Date(timeIntervalSince1970: 1_783_000_000)

        // A calendar pinned well away from UTC; the adapter must override it.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati")) // UTC+14

        let adapter = OpenAIUsageAdapter(
            session: Self.makeSession(),
            calendar: local,
            now: { now }
        )

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)

            guard url.path == "/v1/organization/usage/completions" else {
                return Self.httpResponse(
                    url: url,
                    json: """
                    {"object": "page", "data": [], "has_more": false, "next_page": null}
                    """
                )
            }

            return Self.httpResponse(
                url: url,
                json: """
                {
                  "object": "page",
                  "data": [
                    {
                      "object": "bucket",
                      "start_time": 1782950400,
                      "end_time": 1783036800,
                      "results": [
                        {
                          "object": "organization.usage.completions.result",
                          "model": "gpt-5.4",
                          "input_tokens": 100,
                          "output_tokens": 50,
                          "num_model_requests": 1
                        }
                      ]
                    }
                  ],
                  "has_more": false,
                  "next_page": null
                }
                """
            )
        }

        let result = try await adapter.sync(account: account, secret: "test-secret")

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

        let usageRequest = try XCTUnwrap(
            MockURLProtocol.requests.first { $0.url?.path == "/v1/organization/usage/completions" }
        )
        let startTime = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(usageRequest.url), resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "start_time" }?
                .value
        )

        XCTAssertEqual(
            startTime,
            "1782864000",
            "backfill slices are UTC midnights; routine sync must ask for the same boundary"
        )
    }

    /// The reset date is derived from the period start, so it inherits the same
    /// boundary. A local calendar put it a fraction of a day off for every user
    /// outside UTC.
    func testTheDerivedResetDateIsAUTCMonthBoundary() async throws {
        let account = Self.makeAccount()
        let now = Date(timeIntervalSince1970: 1_783_000_000) // 2026-07-02T13:46:40Z

        var local = Calendar(identifier: .gregorian)
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati")) // UTC+14

        let adapter = OpenAIUsageAdapter(
            session: Self.makeSession(),
            calendar: local,
            now: { now }
        )

        MockURLProtocol.requestHandler = { request in
            Self.httpResponse(
                url: try XCTUnwrap(request.url),
                json: """
                {"object": "page", "data": [], "has_more": false, "next_page": null}
                """
            )
        }

        let result = try await adapter.sync(account: account, secret: "test-secret")

        XCTAssertEqual(
            result.billingPeriod?.resetAt,
            Date(timeIntervalSince1970: 1_785_542_400), // 2026-08-01T00:00:00Z
            "the reset date is the next UTC month boundary"
        )
    }

    private static func fixture(named name: String) -> Data? {
        Bundle(for: OpenAIUsageAdapterTests.self)
            .url(forResource: name, withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func makeAccount() -> Account {
        Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "OpenAI",
            credentialReference: "openai-admin-key",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
    }

    private static func httpResponse(url: URL, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        return (response ?? HTTPURLResponse(), Data(json.utf8))
    }
}

private final class MockURLProtocol: URLProtocol {
    private static let state = State()

    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            state.lock.lock()
            defer { state.lock.unlock() }
            return state.storedRequestHandler
        }
        set {
            state.lock.lock()
            state.storedRequestHandler = newValue
            state.lock.unlock()
        }
    }

    static var requests: [URLRequest] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.storedRequests
    }

    static func reset() {
        state.lock.lock()
        state.storedRequestHandler = nil
        state.storedRequests = []
        state.lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.lock.lock()
        Self.state.storedRequests.append(request)
        let handler = Self.state.storedRequestHandler
        Self.state.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: OpenAIUsageAdapterError.invalidRequest)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class State: @unchecked Sendable {
    let lock = NSLock()
    var storedRequestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    var storedRequests: [URLRequest] = []
}
