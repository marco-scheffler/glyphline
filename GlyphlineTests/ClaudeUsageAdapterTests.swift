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

    /// A web-session subscription tracks quota and nothing else. The cost path has
    /// to say so rather than guess: the two guesses available were reading the
    /// local Claude Code logs — which every web-session account would report as its
    /// own, multiplying one Mac's costs by the number of subscriptions — and
    /// calling the Admin API with a key that does not exist.
    func testWebSessionModeReportsNoCostRatherThanGuessingAtOne() async throws {
        let account = Account(
            id: UUID(),
            providerID: .claude,
            displayName: "Max #1",
            credentialReference: "web-session://\(UUID().uuidString)",
            createdAt: Date(),
            isEnabled: true
        )

        let adapter = ClaudeUsageAdapter(mode: .webSessionQuotaOnly)
        // No secret exists for this source; the adapter must not need one, and must
        // not fail when handed the empty string the scheduler passes instead.
        XCTAssertFalse(adapter.requiresSecret)

        let result = try await adapter.sync(account: account, secret: "")

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.accountID, account.id)
        XCTAssertEqual(result.capabilities.dataQuality, .unavailable)
        XCTAssertFalse(result.capabilities.supportsUsage)
        XCTAssertFalse(result.capabilities.supportsActualCost)
        XCTAssertEqual(
            result.capabilities.message,
            "This subscription tracks quota only; cost comes from your local Claude Code logs account."
        )
        // Nothing invented and nothing borrowed from another account's logs.
        XCTAssertTrue(result.usageSnapshots.isEmpty)
        XCTAssertTrue(result.costSnapshots.isEmpty)
        XCTAssertTrue(result.estimateSnapshots.isEmpty)
        XCTAssertNil(result.billingPeriod)
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
