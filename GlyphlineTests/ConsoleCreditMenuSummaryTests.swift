import AppKit
import SwiftUI
import XCTest
@testable import Glyphline

/// The credit figure beside an account's name in the menu bar panel.
@MainActor
final class ConsoleCreditMenuSummaryTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(
        _ id: String,
        balance minor: Int64?,
        currency: String = "USD",
        expiry: (TimeInterval, Int64)? = nil,
        failure: RateWindowSourceError? = nil
    ) -> ConsoleCreditState {
        var state = ConsoleCreditState(organization: ConsoleOrganization(id: id))
        if let minor {
            state.balance = ConsoleCreditBalance(
                currency: currency,
                exponent: 2,
                balanceMinor: minor,
                nextExpiry: expiry.map { .init(at: now.addingTimeInterval($0.0), amountMinor: $0.1) },
                monthSpendMinor: nil
            )
        }
        state.failure = failure
        return state
    }

    private func amount(_ minor: Int64, _ currency: String = "USD") -> String {
        ConsoleCreditFormatting.amount(minor, exponent: 2, currency: currency, locale: locale)
    }

    func testBalanceAloneWhenNothingLapsesSoon() throws {
        let summary = try XCTUnwrap(ConsoleCreditMenuSummary.make([
            state("a", balance: 15714, expiry: (8 * 86_400, 15213)),
        ], now: now, locale: locale))

        XCTAssertEqual(summary.balanceText, "API \(amount(15714))")
        XCTAssertNil(summary.expiryText)
    }

    func testAnExpiryWithinSevenDaysAddsItsDuration() throws {
        let summary = try XCTUnwrap(ConsoleCreditMenuSummary.make([
            state("a", balance: 15714, expiry: (3 * 86_400, 15213)),
        ], now: now, locale: locale))

        XCTAssertEqual(summary.expiryText, QuotaIndicator.compactDuration(3 * 86_400))
        XCTAssertTrue(summary.accessibilityText.contains(amount(15213)))
    }

    func testNothingKnownYetShowsNothing() {
        XCTAssertNil(ConsoleCreditMenuSummary.make([state("a", balance: nil)], now: now, locale: locale))
        XCTAssertNil(ConsoleCreditMenuSummary.make([
            state("a", balance: nil, failure: .sessionExpired),
        ], now: now, locale: locale))
        XCTAssertNil(ConsoleCreditMenuSummary.make([], now: now, locale: locale))
    }

    func testSeveralOrganizationsInOneCurrencyAreSummed() throws {
        let summary = try XCTUnwrap(ConsoleCreditMenuSummary.make([
            state("a", balance: 1000, expiry: (5 * 86_400, 200)),
            state("b", balance: 500, expiry: (2 * 86_400, 300)),
        ], now: now, locale: locale))

        XCTAssertEqual(summary.balanceText, "API \(amount(1500))")
        // The sooner of the two lapses is the one worth a glance.
        XCTAssertEqual(summary.expiryText, QuotaIndicator.compactDuration(2 * 86_400))
    }

    func testMixedCurrenciesAreNeverAdded() throws {
        let summary = try XCTUnwrap(ConsoleCreditMenuSummary.make([
            state("a", balance: 1000, currency: "USD"),
            state("b", balance: 500, currency: "EUR"),
        ], now: now, locale: locale))

        XCTAssertEqual(summary.balanceText, "API \(amount(1000))")
    }

    /// The whole point of putting it beside the name: the panel must not grow.
    func testTheFigureDoesNotMakeTheSectionTaller() {
        let group = QuotaBarGroup(
            id: UUID(),
            displayName: "Claude gptpro_mscheffler",
            rows: [
                QuotaBarRow(id: "week", label: "Week", remainingFraction: 0.5, detail: "50% left", asOf: nil, severity: .normal),
            ]
        )
        let summary = ConsoleCreditMenuSummary.make([
            state("a", balance: 15714, expiry: (3 * 86_400, 15213)),
        ], now: now, locale: locale)

        let width = MenuBarView.panelWidth - 2 * MenuBarView.panelPadding
        func height(_ credits: [UUID: ConsoleCreditMenuSummary]) -> CGFloat {
            let host = NSHostingView(rootView: AnyView(
                MenuBarQuotaList(groups: [group], credits: credits).frame(width: width)
            ))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        XCTAssertEqual(height([group.id: summary!]), height([:]), accuracy: 0.5)
    }
}
