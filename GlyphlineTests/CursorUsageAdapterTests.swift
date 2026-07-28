import XCTest
@testable import Glyphline

final class CursorUsageAdapterTests: XCTestCase {
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

    func testLocalStatusOnlyReportsUnavailable() async throws {
        let account = Account(
            id: UUID(),
            providerID: .cursor,
            displayName: "Cursor",
            credentialReference: "cursor",
            createdAt: Date(),
            isEnabled: true
        )

        let result = try await CursorUsageAdapter(mode: .localStatusOnly).sync(account: account, secret: "secret")

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.capabilities.dataQuality, .unavailable)
        XCTAssertFalse(result.capabilities.supportsUsage)
        XCTAssertEqual(
            result.capabilities.message,
            "Cursor usage requires a team admin API key. Individual seats have no documented API."
        )
    }

    func testCursorReportsExactCapabilityForTeamAPI() async throws {
        let account = Account(
            id: UUID(),
            providerID: .cursor,
            displayName: "Cursor",
            credentialReference: "cursor",
            createdAt: Date(),
            isEnabled: true
        )

        // Stubbed: this adapter now performs real requests, and the default
        // `URLSession.shared` would turn this test into a live API call.
        StubURLProtocol.enqueue(path: "/teams/filtered-usage-events", body: try fixture("cursor-usage-events-page2"))
        StubURLProtocol.enqueue(path: "/teams/spend", body: try fixture("cursor-spend"))

        let adapter = CursorUsageAdapter(mode: .teamAPI, session: StubURLProtocol.makeSession())
        let result = try await adapter.sync(account: account, secret: "secret")

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.capabilities.dataQuality, .exact)
        XCTAssertTrue(result.capabilities.supportsUsage)
        XCTAssertNil(result.capabilities.message)
    }
}
