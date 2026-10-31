import XCTest
@testable import Glyphline

final class RateWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(used: Double?, resetAt: Date?) -> RateWindow {
        RateWindow(kind: .rollingFiveHours, usedFraction: used, resetAt: resetAt, observedAt: now)
    }

    /// A model's limit is named after the model, as the provider spells it; the
    /// plain windows keep the names they always had.
    func testAModelLimitIsNamedAfterItsModel() {
        let fable = RateWindowID(kind: .weekly, model: "Fable")
        XCTAssertEqual(fable.shortName, "Fable")
        XCTAssertEqual(fable.longName, "Fable · Weekly")

        let plain = RateWindowID(kind: .weekly, model: nil)
        XCTAssertEqual(plain.shortName, RateWindowKind.weekly.shortName)
        XCTAssertEqual(plain.longName, RateWindowKind.weekly.longName)
    }

    /// Only a limit on the whole subscription says whether it can be used. A
    /// spent model allowance leaves every other model running.
    func testOnlyALimitOnTheWholeSubscriptionDecidesHeadroom() {
        XCTAssertTrue(window(used: 0.4, resetAt: nil).decidesHeadroom)
        XCTAssertFalse(
            RateWindow(kind: .weekly, usedFraction: 0.4, resetAt: nil, observedAt: now, model: "Fable")
                .decidesHeadroom
        )
    }

    /// The reading a freshly added subscription produces: a real fraction and no
    /// window running, because a rolling window only starts on first use. Calling
    /// that implausible discarded "nothing consumed, everything left" — the most
    /// useful thing the provider ever reports — and left the account blank.
    func testAMissingResetInstantIsPlausible() {
        XCTAssertTrue(window(used: 0, resetAt: nil).isPlausible(now: now))
        XCTAssertTrue(window(used: 0.42, resetAt: nil).isPlausible(now: now))
        XCTAssertTrue(window(used: nil, resetAt: nil).isPlausible(now: now))
    }

    /// The rule that was there before and must survive: an instant that IS
    /// present still has to be ahead of the observation. Without this the "nil is
    /// plausible" change degenerates into "every reset is plausible".
    func testAResetInstantInThePastIsStillImplausible() {
        XCTAssertFalse(window(used: 0.4, resetAt: now.addingTimeInterval(-1)).isPlausible(now: now))
        XCTAssertFalse(window(used: 0.4, resetAt: now).isPlausible(now: now), "not strictly ahead")
        XCTAssertTrue(window(used: 0.4, resetAt: now.addingTimeInterval(1)).isPlausible(now: now))
    }

    /// A fraction outside 0…1 is a parse that went wrong — a forgotten division
    /// by 100 reads as "400 % used" — and stays rejected whether or not the
    /// window carries an instant. Both branches, so a `guard let resetAt` placed
    /// above the range check cannot slip through.
    func testAFractionOutsideZeroToOneIsImplausibleWithOrWithoutAnInstant() {
        for resetAt in [nil, now.addingTimeInterval(3_600)] as [Date?] {
            XCTAssertFalse(window(used: 1.5, resetAt: resetAt).isPlausible(now: now))
            XCTAssertFalse(window(used: -0.1, resetAt: resetAt).isPlausible(now: now))
            XCTAssertFalse(window(used: 4.0, resetAt: resetAt).isPlausible(now: now))

            XCTAssertTrue(window(used: 0, resetAt: resetAt).isPlausible(now: now))
            XCTAssertTrue(window(used: 1, resetAt: resetAt).isPlausible(now: now))
        }
    }
}
