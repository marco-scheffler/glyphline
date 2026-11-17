import XCTest
@testable import Glyphline

final class ConsoleCreditRuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func balance(
        minor: Int64 = 10_000,
        exponent: Int = 2,
        expiresIn interval: TimeInterval? = nil
    ) -> ConsoleCreditBalance {
        ConsoleCreditBalance(
            currency: "USD",
            exponent: exponent,
            balanceMinor: minor,
            nextExpiry: interval.map { .init(at: now.addingTimeInterval($0), amountMinor: 350) },
            monthSpendMinor: nil
        )
    }

    func testExpiryInsideThreeDaysIsAnnounced() {
        let expiry = ConsoleCreditRule.expiringSoon(balance(expiresIn: 2 * 86_400), now: now)
        XCTAssertEqual(expiry, .init(at: now.addingTimeInterval(2 * 86_400), amountMinor: 350))
        XCTAssertNotNil(ConsoleCreditRule.expiringSoon(balance(expiresIn: 3 * 86_400), now: now))
    }

    func testExpiryFourDaysOutIsNot() {
        XCTAssertNil(ConsoleCreditRule.expiringSoon(balance(expiresIn: 4 * 86_400), now: now))
    }

    func testExpiryAlreadyPastIsNot() {
        XCTAssertNil(ConsoleCreditRule.expiringSoon(balance(expiresIn: -60), now: now))
        XCTAssertNil(ConsoleCreditRule.expiringSoon(balance(expiresIn: 0), now: now))
        XCTAssertNil(ConsoleCreditRule.expiringSoon(balance(), now: now))
    }

    func testLowBelowFiveMajorUnits() {
        XCTAssertTrue(ConsoleCreditRule.isLow(balance(minor: 499)))
        XCTAssertFalse(ConsoleCreditRule.isLow(balance(minor: 500)))
    }

    func testLowRespectsExponentZero() {
        XCTAssertTrue(ConsoleCreditRule.isLow(balance(minor: 4, exponent: 0)))
        XCTAssertFalse(ConsoleCreditRule.isLow(balance(minor: 5, exponent: 0)))
    }
}
