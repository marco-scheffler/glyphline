import XCTest
@testable import Glyphline

final class QuotaCardModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let fiveHours: TimeInterval = 5 * 60 * 60

    private func window(
        _ kind: RateWindowKind = .rollingFiveHours,
        used: Double?,
        resetIn: TimeInterval?
    ) -> RateWindow {
        RateWindow(
            kind: kind,
            usedFraction: used,
            resetAt: resetIn.map { now.addingTimeInterval($0) },
            observedAt: now
        )
    }

    /// The marker is the whole point of the card: half the window gone with half
    /// the budget spent is exactly on pace, so the bar and the marker coincide.
    func testHalfWayThroughTheWindowWithHalfSpentSitsOnTheMarker() throws {
        let card = try XCTUnwrap(
            QuotaCardModel.make(for: window(used: 0.5, resetIn: fiveHours / 2), now: now)
        )

        XCTAssertEqual(card.pacePosition ?? .nan, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(card.usedFraction, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(card.headroomFraction, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(card.headroomPercent, 50)
        XCTAssertEqual(card.usedPercent, 50)
        XCTAssertEqual(card.usageText, "50% used")
        XCTAssertEqual(card.headroomText, "50% left")
        XCTAssertEqual(card.state, .ok)
    }

    /// A quarter of the window gone with 80% spent is spending far faster than
    /// the window allows; the same instant with 10% spent is not.
    func testBurningFasterThanTheMarkerWarnsAndSlowerDoesNot() throws {
        let quarterGone = fiveHours * 0.75

        let fast = try XCTUnwrap(
            QuotaCardModel.make(for: window(used: 0.8, resetIn: quarterGone), now: now)
        )
        XCTAssertEqual(fast.pacePosition ?? .nan, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(fast.state, .warn)

        let slow = try XCTUnwrap(
            QuotaCardModel.make(for: window(used: 0.1, resetIn: quarterGone), now: now)
        )
        XCTAssertEqual(slow.pacePosition ?? .nan, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(slow.state, .ok)
    }

    /// A spent window says so, and its headroom bottoms out at zero rather than
    /// going negative — a negative width draws as a bar running the wrong way.
    func testSpentWindowIsSpentAndNeverReportsNegativeHeadroom() throws {
        let spent = try XCTUnwrap(
            QuotaCardModel.make(for: window(used: 1.0, resetIn: fiveHours / 2), now: now)
        )
        XCTAssertEqual(spent.state, .spent)
        XCTAssertEqual(spent.headroomFraction, 0, accuracy: 0.000_001)
        XCTAssertEqual(spent.headroomPercent, 0)

        // A provider that over-reports must not push the headroom below zero.
        let overspent = try XCTUnwrap(
            QuotaCardModel.make(for: window(used: 1.5, resetIn: fiveHours / 2), now: now)
        )
        XCTAssertEqual(overspent.state, .spent)
        XCTAssertGreaterThanOrEqual(overspent.headroomFraction, 0)
        XCTAssertGreaterThanOrEqual(overspent.headroomPercent, 0)
        XCTAssertLessThanOrEqual(overspent.usedFraction, 1)
    }

    /// Clocks drift and syncs arrive late, so a reset can already be in the past.
    /// The marker must stay a finite number in 0…1: a NaN propagates into the
    /// layout as a blank card rather than as an obvious error.
    func testResetAlreadyInThePastStaysAFiniteMarkerInRange() throws {
        let card = try XCTUnwrap(
            QuotaCardModel.make(for: window(used: 0.4, resetIn: -3600), now: now)
        )

        let pace = try XCTUnwrap(card.pacePosition)
        XCTAssertTrue(pace.isFinite)
        XCTAssertFalse(pace.isNaN)
        XCTAssertGreaterThanOrEqual(pace, 0)
        XCTAssertLessThanOrEqual(pace, 1)
        XCTAssertEqual(pace, 1, accuracy: 0.000_001)
    }

    /// The observation instant, not the window start, is what a marker before
    /// the window's beginning would come from — it still clamps at zero.
    func testMarkerNeverGoesBelowZeroBeforeTheWindowStarts() throws {
        let card = try XCTUnwrap(
            QuotaCardModel.make(for: window(used: 0.1, resetIn: fiveHours * 2), now: now)
        )
        let pace = try XCTUnwrap(card.pacePosition)
        XCTAssertTrue(pace.isFinite)
        XCTAssertEqual(pace, 0, accuracy: 0.000_001)
    }

    /// The card must not compute a second opinion about when the window empties.
    /// Pinning the equality is what makes the reuse real rather than a comment.
    func testPaceTextIsExactlyQuotaIndicatorsForTheSameInput() {
        let fixtures = [
            window(used: 0.5, resetIn: fiveHours / 2),
            window(used: 0.9, resetIn: fiveHours / 4),
            window(used: 0.1, resetIn: fiveHours * 0.9),
            window(used: 1.0, resetIn: fiveHours / 2),
            window(used: 0.0, resetIn: fiveHours / 2),
            window(.weekly, used: 0.75, resetIn: 24 * 60 * 60),
            window(.billingCycle, used: 0.5, resetIn: 24 * 60 * 60),
            window(used: 0.4, resetIn: -3600)
        ]

        for fixture in fixtures {
            let card = QuotaCardModel.make(for: fixture, now: now)
            XCTAssertEqual(
                card?.paceText,
                QuotaIndicator.paceText(for: fixture, now: now),
                "pace text drifted for \(fixture)"
            )
        }
    }

    /// A billing cycle has no span the app may claim to know, so it gets no
    /// marker at all rather than a made-up one.
    func testBillingCycleHasNoMarker() throws {
        let card = try XCTUnwrap(
            QuotaCardModel.make(for: window(.billingCycle, used: 0.9, resetIn: 24 * 60 * 60), now: now)
        )
        XCTAssertNil(card.pacePosition)
        XCTAssertEqual(card.state, .ok)
    }

    /// Without a reported fraction there is no bar to draw and no honest state.
    func testWindowWithoutAFractionProducesNoCard() {
        XCTAssertNil(QuotaCardModel.make(for: window(used: nil, resetIn: fiveHours), now: now))
    }
}
