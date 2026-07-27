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
        XCTAssertEqual(result.capabilities.message, "Claude non-admin credentials are unavailable.")
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

        let result = try await ClaudeUsageAdapter(mode: .adminAPI).sync(account: account, secret: "secret")

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.capabilities.dataQuality, .exact)
        XCTAssertTrue(result.capabilities.supportsUsage)
        XCTAssertTrue(result.capabilities.supportsActualCost)
        XCTAssertEqual(result.capabilities.message, "Claude admin API mode is exact.")
    }
}
