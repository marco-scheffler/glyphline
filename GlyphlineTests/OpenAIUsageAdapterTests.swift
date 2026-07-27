import XCTest
@testable import Glyphline

final class OpenAIUsageAdapterTests: XCTestCase {
    func testDecodesUsageFixture() throws {
        let data = try XCTUnwrap(Self.fixture(named: "openai-usage"))

        let decoded = try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)

        XCTAssertEqual(decoded.data.count, 1)
        XCTAssertEqual(decoded.data.first?.results.count, 1)
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

    private static func fixture(named name: String) -> Data? {
        Bundle(for: OpenAIUsageAdapterTests.self)
            .url(forResource: name, withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
    }
}
