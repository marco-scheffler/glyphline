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
        XCTAssertEqual(
            try XCTUnwrap(fiveHour.resetAt).timeIntervalSince1970,
            1_785_321_000.695306,
            accuracy: 0.001
        )
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

    /// The full production key list, so the fixture matches what the endpoint
    /// really sends. Every value here is invented.
    private func productionShaped(fiveHour: String, sevenDay: String) -> Data {
        Data("""
            {
              "five_hour": \(fiveHour),
              "seven_day": \(sevenDay),
              "seven_day_opus": null,
              "seven_day_sonnet": null,
              "seven_day_cowork": null,
              "seven_day_oauth_apps": null,
              "seven_day_omelette": null,
              "omelette_promotional": null,
              "amber_ladder": null,
              "cinder_cove": null,
              "iguana_necktie": null,
              "nimbus_quill": null,
              "tangelo": null,
              "spend": 0,
              "extra_usage": null,
              "limits": {},
              "member_dashboard_available": false
            }
            """.utf8)
    }

    private static let completeWindow = #"{"utilization": 7.0, "resets_at": "2026-08-03T22:59:59.695335+00:00"}"#

    /// A null `resets_at` used to take the whole window with it, including the
    /// `utilization` beside it. The fraction is the useful half of the reading
    /// and it is reported correctly, so it must survive on its own.
    func testAWindowWithoutAResetInstantKeepsItsFractionAndTheSiblingSurvives() throws {
        let json = productionShaped(
            fiveHour: #"{"utilization": 12.0, "resets_at": null}"#,
            sevenDay: Self.completeWindow
        )

        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.map(\.kind), [.rollingFiveHours, .weekly])

        let fiveHour = try XCTUnwrap(windows.first { $0.kind == .rollingFiveHours })
        XCTAssertNil(fiveHour.resetAt, "a null resets_at is no instant, not an invented one")
        XCTAssertEqual(try XCTUnwrap(fiveHour.usedFraction), 0.12, accuracy: 0.0001)

        let weekly = try XCTUnwrap(windows.first { $0.kind == .weekly })
        XCTAssertNotNil(weekly.resetAt, "the sibling's own instant is untouched")
        XCTAssertEqual(try XCTUnwrap(weekly.usedFraction), 0.07, accuracy: 0.0001)
    }

    /// The exact shape a freshly added subscription returns: both windows
    /// present, both `resets_at` null, both `utilization` a real number. A
    /// rolling window only starts on first use, so there is genuinely nothing to
    /// reset — and "0% consumed" is the most useful thing the endpoint ever
    /// says. This response used to yield no windows at all and the account
    /// showed nothing.
    func testAnUnusedSubscriptionYieldsBothWindowsWithNoResetInstant() throws {
        let json = productionShaped(
            fiveHour: #"{"limit_dollars": null, "remaining_dollars": null, "resets_at": null, "used_dollars": null, "utilization": 0}"#,
            sevenDay: #"{"limit_dollars": null, "remaining_dollars": null, "resets_at": null, "used_dollars": null, "utilization": 0}"#
        )

        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(Set(windows.map(\.kind)), [.rollingFiveHours, .weekly])
        XCTAssertTrue(windows.allSatisfy { $0.resetAt == nil })
        // Zero, and present — distinct from the nil that means "usage unknown".
        for window in windows {
            XCTAssertEqual(try XCTUnwrap(window.usedFraction), 0, accuracy: 1e-12)
        }
        // And the ledger must accept them, or the decode fix changes nothing.
        XCTAssertTrue(windows.allSatisfy { $0.isPlausible(now: observedAt) })
    }

    func testAWindowWithoutUtilizationKeepsItsResetInstantAndReportsUsageAsUnknown() throws {
        let json = productionShaped(
            fiveHour: #"{"utilization": null, "resets_at": "2026-07-29T10:30:00Z"}"#,
            sevenDay: "null"
        )

        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.map(\.kind), [.rollingFiveHours])
        // Nil, not 0 — "unknown" must not be rendered as "nothing used".
        XCTAssertNil(windows[0].usedFraction)
    }

    func testBothWindowsCompleteStillYieldBoth() throws {
        let json = productionShaped(
            fiveHour: #"{"utilization": 12.0, "resets_at": "2026-07-29T10:30:00Z"}"#,
            sevenDay: Self.completeWindow
        )

        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(Set(windows.map(\.kind)), [.rollingFiveHours, .weekly])
        let fiveHour = try XCTUnwrap(windows.first { $0.kind == .rollingFiveHours })
        XCTAssertEqual(try XCTUnwrap(fiveHour.usedFraction), 0.12, accuracy: 0.0001)
    }

    /// A timestamp we cannot parse costs that window its instant and nothing
    /// else — not the fraction beside it, and above all not the sibling window,
    /// which decodes through the same date strategy.
    func testAMalformedResetInstantCostsOnlyThatWindowsInstant() throws {
        let json = productionShaped(
            fiveHour: #"{"utilization": 12.0, "resets_at": "not-a-timestamp"}"#,
            sevenDay: Self.completeWindow
        )

        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.map(\.kind), [.rollingFiveHours, .weekly])

        let fiveHour = try XCTUnwrap(windows.first { $0.kind == .rollingFiveHours })
        XCTAssertNil(fiveHour.resetAt)
        XCTAssertEqual(try XCTUnwrap(fiveHour.usedFraction), 0.12, accuracy: 0.0001)

        XCTAssertNotNil(try XCTUnwrap(windows.first { $0.kind == .weekly }).resetAt)
    }

    func testAWholeWindowValueBeingNullStaysTolerated() throws {
        let json = productionShaped(fiveHour: "null", sevenDay: Self.completeWindow)

        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.map(\.kind), [.weekly])
    }

    func testTheCodenameAndBillingFieldsAreIgnoredButDoNotBreakDecoding() throws {
        let json = productionShaped(
            fiveHour: #"{"utilization": 12.0, "resets_at": "2026-07-29T10:30:00Z"}"#,
            sevenDay: Self.completeWindow
        )

        let response = try ClaudeUsageResponse.decode(json)

        XCTAssertNotNil(response.fiveHour)
        XCTAssertNotNil(response.sevenDay)
        XCTAssertEqual(response.rateWindows(observedAt: observedAt).count, 2)
    }

    func testAnUnparseableBodyThrows() {
        XCTAssertThrowsError(try ClaudeUsageResponse.decode(Data("<html>sign in</html>".utf8)))
    }
}
