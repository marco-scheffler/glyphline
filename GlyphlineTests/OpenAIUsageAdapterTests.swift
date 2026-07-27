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
        let adapter = OpenAIUsageAdapter(
            session: Self.makeSession(),
            calendar: Self.utcCalendar,
            now: { now }
        )

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
        let adapter = OpenAIUsageAdapter(
            session: Self.makeSession(),
            calendar: Self.utcCalendar,
            now: { now }
        )

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

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

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
