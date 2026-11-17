import XCTest

@testable import Glyphline

/// What one API organisation's credit block says. Expected amounts and dates are
/// built with `.formatted(...)`, never hardcoded: the machine's locale decides
/// the separators.
@MainActor
final class ConsoleCreditCardModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let locale = Locale(identifier: "en_US")

    private func usd(_ minor: Int64) -> String {
        (Decimal(minor) / 100).formatted(.currency(code: "USD").locale(locale))
    }

    private func state(
        currency: String = "USD",
        expiry: ConsoleCreditBalance.Expiry? = nil,
        hasBalance: Bool = true,
        failure: RateWindowSourceError? = nil
    ) -> ConsoleCreditState {
        ConsoleCreditState(
            organization: ConsoleOrganization(id: "org-1"),
            balance: hasBalance
                ? ConsoleCreditBalance(
                    currency: currency,
                    exponent: 2,
                    balanceMinor: 15_700,
                    nextExpiry: expiry,
                    monthSpendMinor: 4_200
                )
                : nil,
            failure: failure
        )
    }

    func testFullStateRendersAllLines() {
        let at = now.addingTimeInterval(12 * 86_400)
        let model = ConsoleCreditCardModel.make(
            state(expiry: .init(at: at, amountMinor: 5_000)),
            position: 1, of: 1, now: now, locale: locale
        )
        let date = at.formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).locale(locale))
        let duration = QuotaIndicator.compactDuration(12 * 86_400)

        XCTAssertEqual(model.id, "org-1")
        XCTAssertEqual(model.title, "API credit")
        XCTAssertEqual(model.balanceText, "\(usd(15_700)) left")
        XCTAssertEqual(model.expiryText, "\(usd(5_000)) expires \(date) (in \(duration))")
        XCTAssertFalse(model.expiryIsUrgent)
        XCTAssertEqual(model.spendText, "\(usd(4_200)) spent this month")
        XCTAssertNil(model.message)
    }

    func testNoExpiryLeavesTheLineOut() {
        let model = ConsoleCreditCardModel.make(state(), position: 1, of: 1, now: now, locale: locale)
        XCTAssertNil(model.expiryText)
        XCTAssertFalse(model.expiryIsUrgent)
        XCTAssertNotNil(model.balanceText)
    }

    func testExpiryWithinSevenDaysIsUrgent() {
        let at = now.addingTimeInterval(7 * 86_400)
        let model = ConsoleCreditCardModel.make(
            state(expiry: .init(at: at, amountMinor: 100)), position: 1, of: 1, now: now, locale: locale
        )
        XCTAssertTrue(model.expiryIsUrgent)
    }

    func testEightDaysIsNot() {
        let at = now.addingTimeInterval(8 * 86_400)
        let model = ConsoleCreditCardModel.make(
            state(expiry: .init(at: at, amountMinor: 100)), position: 1, of: 1, now: now, locale: locale
        )
        XCTAssertFalse(model.expiryIsUrgent)
    }

    func testFailureShowsTheConsoleMessage() {
        let model = ConsoleCreditCardModel.make(
            state(hasBalance: false, failure: .sessionExpired), position: 1, of: 1, now: now, locale: locale
        )
        XCTAssertEqual(model.message, "Your Claude Console sign-in has expired. Connect the Console again.")
        XCTAssertNil(model.balanceText)
        XCTAssertNil(model.spendText)
    }

    func testFailureKeepsTheLastBalance() {
        let model = ConsoleCreditCardModel.make(
            state(failure: .transportFailure), position: 1, of: 1, now: now, locale: locale
        )
        XCTAssertEqual(model.balanceText, "\(usd(15_700)) left")
        XCTAssertEqual(model.message, RateWindowSourceError.transportFailure.message)
    }

    func testTitleIsNumberedOnlyWhenThereAreSeveral() {
        XCTAssertEqual(ConsoleCreditCardModel.make(state(), position: 1, of: 1, now: now).title, "API credit")
        XCTAssertEqual(ConsoleCreditCardModel.make(state(), position: 1, of: 2, now: now).title, "API credit 1")
        XCTAssertEqual(ConsoleCreditCardModel.make(state(), position: 2, of: 2, now: now).title, "API credit 2")
    }

    func testAmountsFollowTheCurrency() {
        let model = ConsoleCreditCardModel.make(state(currency: "EUR"), position: 1, of: 1, now: now, locale: locale)
        let eur = (Decimal(15_700) / 100).formatted(.currency(code: "EUR").locale(locale))
        XCTAssertEqual(model.balanceText, "\(eur) left")
    }

    func testAnExpiryAlreadyPastIsLeftOut() {
        for at in [now, now.addingTimeInterval(-3_600)] {
            let model = ConsoleCreditCardModel.make(
                state(expiry: .init(at: at, amountMinor: 100)), position: 1, of: 1, now: now, locale: locale
            )
            XCTAssertNil(model.expiryText)
            XCTAssertFalse(model.expiryIsUrgent)
            XCTAssertNotNil(model.balanceText)
        }
    }

    func testAConnectedOrganizationWithNoStateYetIsBeingChecked() {
        let orgs = [ConsoleOrganization(id: "org-1"), ConsoleOrganization(id: "org-2")]
        let models = ConsoleCreditCardModel.models(
            for: orgs, states: [state()], now: now, locale: locale
        )

        XCTAssertEqual(models.map(\.id), ["org-1", "org-2"])
        XCTAssertEqual(models[0].balanceText, "\(usd(15_700)) left")
        XCTAssertNil(models[0].message)
        XCTAssertEqual(models[1].title, "API credit 2")
        XCTAssertEqual(models[1].message, "Checking…")
        XCTAssertNil(models[1].balanceText)
    }
}
