import XCTest
@testable import Glyphline

final class ClaudeUsageQuotaDTOsTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        return try Data(contentsOf: XCTUnwrap(url))
    }

    func testUtilizationBecomesAFractionAndNotAPercentage() throws {
        let response = try ClaudeUsageResponse.decode(fixture("claude-usage"))
        let windows = response.rateWindows(observedAt: observedAt)

        let fiveHour = try XCTUnwrap(windows.first { $0.kind == .rollingFiveHours })
        // 4.0 percent must become 0.04, not 4.0 — the latter is rejected by
        // isPlausible and would surface as a permanently grey account.
        XCTAssertEqual(try XCTUnwrap(fiveHour.usedFraction), 0.04, accuracy: 0.0001)

        let weekly = try XCTUnwrap(windows.first { $0.kind == .weekly })
        XCTAssertEqual(try XCTUnwrap(weekly.usedFraction), 0.03, accuracy: 0.0001)
    }

    func testBothWindowsAreProducedWithTheirResetInstants() throws {
        let response = try ClaudeUsageResponse.decode(fixture("claude-usage"))
        let windows = response.rateWindows(observedAt: observedAt)

        XCTAssertEqual(Set(windows.map(\.kind)), [.rollingFiveHours, .weekly])
        XCTAssertTrue(windows.allSatisfy { $0.observedAt == observedAt })

        let fiveHour = try XCTUnwrap(windows.first { $0.kind == .rollingFiveHours })
        // 2026-07-29T10:30:00.695306+00:00 — microsecond precision must parse.
        XCTAssertEqual(fiveHour.resetAt.timeIntervalSince1970, 1_785_321_000.695306, accuracy: 0.001)
    }

    func testDecodingSurvivesWithEveryCodenameFieldRemoved() throws {
        // tangelo, nimbus_quill and friends are internal and unstable. Nothing
        // may depend on them; their absence must not break decoding.
        let response = try ClaudeUsageResponse.decode(fixture("claude-usage-minimal"))
        let windows = response.rateWindows(observedAt: observedAt)

        XCTAssertEqual(Set(windows.map(\.kind)), [.rollingFiveHours, .weekly])
        XCTAssertEqual(try XCTUnwrap(windows.first { $0.kind == .rollingFiveHours }.map(\.usedFraction)), 1.0)
    }

    func testAWindowMissingFromTheResponseIsSimplyAbsent() throws {
        let json = Data("""
            {"five_hour": {"utilization": 12.0, "resets_at": "2026-07-29T10:30:00Z"}}
            """.utf8)
        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.map(\.kind), [.rollingFiveHours])
    }

    func testAnUnparseableBodyThrows() {
        XCTAssertThrowsError(try ClaudeUsageResponse.decode(Data("<html>sign in</html>".utf8)))
    }
}
