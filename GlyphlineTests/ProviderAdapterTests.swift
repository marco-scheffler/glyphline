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

    func testFixtureAdapterUsesDifferentSnapshotIDsForDifferentAccounts() async throws {
        let adapter = FixtureProviderAdapter(providerID: .openAI)
        let firstAccount = Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "Fixture One",
            credentialReference: "fixture-one",
            createdAt: Date(),
            isEnabled: true
        )
        let secondAccount = Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "Fixture Two",
            credentialReference: "fixture-two",
            createdAt: Date(),
            isEnabled: true
        )

        let firstResult = try await adapter.sync(account: firstAccount, secret: "fixture")
        let secondResult = try await adapter.sync(account: secondAccount, secret: "fixture")

        XCTAssertEqual(firstResult.usageSnapshots.first?.quality, .exact)
        XCTAssertEqual(secondResult.usageSnapshots.first?.quality, .exact)
        XCTAssertEqual(firstResult.estimateSnapshots.first?.quality, .estimated)
        XCTAssertEqual(secondResult.estimateSnapshots.first?.quality, .estimated)
        XCTAssertNotEqual(firstResult.usageSnapshots.first?.id, secondResult.usageSnapshots.first?.id)
        XCTAssertNotEqual(firstResult.estimateSnapshots.first?.id, secondResult.estimateSnapshots.first?.id)
    }
}
