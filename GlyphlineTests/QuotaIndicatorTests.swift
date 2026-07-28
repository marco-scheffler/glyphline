import XCTest
@testable import Glyphline

final class QuotaIndicatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let freshness: TimeInterval = 3_600

    private func account(
        _ name: String,
        used: Double?,
        observedMinutesAgo: Double = 0,
        message: String? = nil
    ) -> QuotaAccountState {
        let observed = now.addingTimeInterval(-observedMinutesAgo * 60)
        return QuotaAccountState(
            accountID: UUID(),
            displayName: name,
            windows: used == nil && message != nil ? [] : [
                RateWindow(
                    kind: .rollingFiveHours,
                    usedFraction: used,
                    resetAt: now.addingTimeInterval(1_800),
                    observedAt: observed
                ),
            ],
            message: message
        )
    }

    func testHeadroomAnywhereIsGreen() {
        let states = [account("A", used: 1.0), account("B", used: 0.3)]
        XCTAssertEqual(QuotaIndicator.light(for: states, now: now, freshness: freshness), .green)
    }

    func testEverythingKnownAndExhaustedIsRed() {
        let states = [account("A", used: 1.0), account("B", used: 1.0)]
        XCTAssertEqual(QuotaIndicator.light(for: states, now: now, freshness: freshness), .red)
    }

    func testExhaustedPlusOneUnknownIsGreyNotRed() {
        // The unknown account might have capacity. Red would assert knowledge we
        // do not have.
        let states = [
            account("A", used: 1.0),
            account("B", used: 1.0),
            account("C", used: nil, message: "no response since 14:02"),
        ]
        XCTAssertEqual(QuotaIndicator.light(for: states, now: now, freshness: freshness), .grey)
    }

    func testStaleObservationsCountAsUnknown() {
        let states = [account("A", used: 0.1, observedMinutesAgo: 120)]
        XCTAssertEqual(QuotaIndicator.light(for: states, now: now, freshness: freshness), .grey)
    }

    func testAWindowWithoutAFractionCannotDecideTheLight() {
        let states = [account("A", used: nil)]
        XCTAssertEqual(QuotaIndicator.light(for: states, now: now, freshness: freshness), .grey)
    }

    func testNextFreeNamesAnAccountWithHeadroomAsAvailableNow() {
        let states = [account("Max #1", used: 1.0), account("Max #2", used: 0.2)]
        XCTAssertEqual(QuotaIndicator.nextFree(for: states, now: now, freshness: freshness), "Max #2 — now")
    }

    func testNextFreeNamesTheEarliestResetWhenAllAreExhausted() {
        let states = [account("Max #1", used: 1.0), account("Max #2", used: 1.0)]
        XCTAssertNotNil(QuotaIndicator.nextFree(for: states, now: now, freshness: freshness))
    }
}
