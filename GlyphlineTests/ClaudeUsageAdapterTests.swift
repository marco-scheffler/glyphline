import XCTest
@testable import Glyphline

final class ClaudeUsageAdapterTests: XCTestCase {
    func testClaudeReportsUnavailableWithoutAdminAPI() async throws {
        let account = Account(
            id: UUID(),
            providerID: .claude,
            displayName: "Claude",
            credentialReference: "claude",
            createdAt: Date(),
            isEnabled: true
        )

        let result = try await ClaudeUsageAdapter(mode: .requiresAdminKey).sync(account: account, secret: "secret")

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.capabilities.dataQuality, .unavailable)
        XCTAssertFalse(result.capabilities.supportsUsage)
        XCTAssertEqual(result.capabilities.message, "Claude usage requires an organization admin credential.")
    }

    func testClaudeReportsExactCapabilityForAdminAPI() async throws {
        let account = Account(
            id: UUID(),
            providerID: .claude,
            displayName: "Claude",
            credentialReference: "claude",
            createdAt: Date(),
            isEnabled: true
        )

        // The admin API mode now performs real requests, so it is exercised against
        // stubbed responses rather than the removed capability stub.
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let empty = Data(#"{"data": [], "has_more": false, "next_page": null}"#.utf8)
        StubURLProtocol.enqueue(path: "/v1/organizations/usage_report/messages", body: empty)
        StubURLProtocol.enqueue(path: "/v1/organizations/cost_report", body: empty)

        let result = try await ClaudeUsageAdapter(mode: .adminAPI, session: StubURLProtocol.makeSession())
            .sync(account: account, secret: "sk-ant-admin-secret")

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.capabilities.dataQuality, .exact)
        XCTAssertTrue(result.capabilities.supportsUsage)
        XCTAssertTrue(result.capabilities.supportsActualCost)
        XCTAssertNil(result.capabilities.message)
    }
}
