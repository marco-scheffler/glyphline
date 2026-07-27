import XCTest
@testable import Glyphline

final class CursorUsageAdapterTests: XCTestCase {
    func testCursorReportsPartialCapabilityWithoutTeamAPI() async throws {
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
        XCTAssertEqual(result.capabilities.dataQuality, .partial)
        XCTAssertFalse(result.capabilities.supportsUsage)
        XCTAssertEqual(result.capabilities.message, "Cursor local-status-only mode is partial.")
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

        let result = try await CursorUsageAdapter(mode: .teamAPI).sync(account: account, secret: "secret")

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.capabilities.dataQuality, .exact)
        XCTAssertTrue(result.capabilities.supportsUsage)
        XCTAssertEqual(result.capabilities.message, "Cursor team/API mode is exact.")
    }
}
