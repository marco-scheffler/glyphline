import XCTest
@testable import Glyphline

final class ProviderAdapterTests: XCTestCase {
    func testFixtureAdapterReturnsExactUsageAndEstimatedCost() async throws {
        let account = Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "Fixture",
            credentialReference: "fixture",
            createdAt: Date(),
            isEnabled: true
        )
        let adapter = FixtureProviderAdapter(providerID: .openAI)

        let result = try await adapter.sync(account: account, secret: "fixture")

        XCTAssertEqual(result.providerID, .openAI)
        XCTAssertEqual(result.usageSnapshots.count, 1)
        XCTAssertEqual(result.usageSnapshots.first?.quality, .exact)
        XCTAssertEqual(result.estimateSnapshots.count, 1)
        XCTAssertEqual(result.estimateSnapshots.first?.quality, .estimated)
    }
}
