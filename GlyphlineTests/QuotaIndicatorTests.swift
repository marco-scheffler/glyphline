import XCTest
@testable import Glyphline

final class QuotaIndicatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let freshness: TimeInterval = 3_600

    /// An account carrying exactly one window.
    private func account(
        _ name: String,
        used: Double?,
        observedMinutesAgo: Double = 0,
        resetMinutesFromNow: Double = 30
    ) -> QuotaAccountState {
        accountWith(
            name,
            windows: [window(used: used, observedMinutesAgo: observedMinutesAgo, resetMinutesFromNow: resetMinutesFromNow)]
        )
    }

    /// An account that failed to answer: no windows at all, only a message.
    /// Kept distinct from `account(_:used: nil)` — that one *has* a window whose
    /// fraction is unknown. Both yield an unknown verdict, by different routes.
    private func silentAccount(_ name: String, message: String) -> QuotaAccountState {
        accountWith(name, windows: [], message: message)
    }

    private func accountWith(
        _ name: String,
        windows: [RateWindow],
        message: String? = nil
    ) -> QuotaAccountState {
        QuotaAccountState(
            accountID: UUID(),
            displayName: name,
            windows: windows,
            message: message
        )
    }

    private func window(
        kind: RateWindowKind = .rollingFiveHours,
        used: Double?,
        observedMinutesAgo: Double = 0,
        resetMinutesFromNow: Double = 30
    ) -> RateWindow {
        RateWindow(
            kind: kind,
            usedFraction: used,
            resetAt: now.addingTimeInterval(resetMinutesFromNow * 60),
            observedAt: now.addingTimeInterval(-observedMinutesAgo * 60)
        )
    }

    /// Mirrors the formatter `nextFree` builds, so assertions do not hardcode a
    /// locale's clock format.
    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
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
            silentAccount("C", message: "no response since 14:02"),
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
        // Distinct reset instants, so "earliest" is actually discriminated: an
        // implementation returning max(), or the first element, fails here.
        let states = [
            account("Max #1", used: 1.0, resetMinutesFromNow: 180),
            account("Max #2", used: 1.0, resetMinutesFromNow: 60),
        ]
        let expected = "Max #2 at \(shortTime(now.addingTimeInterval(60 * 60)))"
        XCTAssertEqual(QuotaIndicator.nextFree(for: states, now: now, freshness: freshness), expected)
    }

    func testNextFreeIgnoresResetsFromStaleWindows() {
        // The light discards the stale weekly window as unknown; nextFree must
        // agree, rather than naming a reset instant it no longer believes.
        let states = [
            accountWith("Max #1", windows: [
                window(kind: .rollingFiveHours, used: 1.0, resetMinutesFromNow: 120),
                window(kind: .weekly, used: 1.0, observedMinutesAgo: 1_440, resetMinutesFromNow: 30),
            ]),
        ]
        let expected = "Max #1 at \(shortTime(now.addingTimeInterval(120 * 60)))"
        XCTAssertEqual(QuotaIndicator.nextFree(for: states, now: now, freshness: freshness), expected)
    }

    func testNextFreeIgnoresResetsThatHaveAlreadyElapsed() {
        // A window can be fresh and still carry a reset instant in the past.
        let states = [
            accountWith("Max #1", windows: [
                window(kind: .rollingFiveHours, used: 1.0, resetMinutesFromNow: 120),
                window(kind: .weekly, used: 1.0, resetMinutesFromNow: -15),
            ]),
        ]
        let expected = "Max #1 at \(shortTime(now.addingTimeInterval(120 * 60)))"
        XCTAssertEqual(QuotaIndicator.nextFree(for: states, now: now, freshness: freshness), expected)
    }

    func testNoAccountsIsGreyNotRed() {
        // Without the empty guard this returns .red: [].allSatisfy is vacuously
        // true, so "every account is exhausted" holds over no accounts at all.
        XCTAssertEqual(QuotaIndicator.light(for: [], now: now, freshness: freshness), .grey)
    }

    func testAStaleWindowCannotOverrideAFreshOneOnTheSameAccount() {
        // Filtering is per window, not per account: the fresh window decides
        // alone and the stale exhausted one contributes nothing.
        let states = [
            accountWith("A", windows: [
                window(kind: .rollingFiveHours, used: 0.2),
                window(kind: .weekly, used: 1.0, observedMinutesAgo: 1_440),
            ]),
        ]
        XCTAssertEqual(QuotaIndicator.light(for: states, now: now, freshness: freshness), .green)
    }

    func testEachLightStateHasItsOwnSymbol() {
        let symbols = Set([
            QuotaIndicator.symbolName(for: .green),
            QuotaIndicator.symbolName(for: .red),
            QuotaIndicator.symbolName(for: .grey),
        ])
        XCTAssertEqual(symbols.count, 3, "the three states must visually distinguishable")
    }

    /// Grey is not a rare degraded state: the access spike found no provider route
    /// to rate windows, so it is what every user sees until a real source ships.
    /// The state carrying no information must not cost the app its identity in the
    /// menu bar.
    func testGreyRendersTheAppsOwnGlyphRatherThanANeutralDot() {
        XCTAssertEqual(QuotaIndicator.symbolName(for: .grey), QuotaIndicator.appSymbolName)
        XCTAssertNotEqual(QuotaIndicator.symbolName(for: .green), QuotaIndicator.appSymbolName)
        XCTAssertNotEqual(QuotaIndicator.symbolName(for: .red), QuotaIndicator.appSymbolName)
    }

    /// The menu bar item renders only a symbol, so this string is the whole of
    /// what a VoiceOver user gets. It must name the app and the state.
    func testEachLightStateHasItsOwnAccessibilityLabel() {
        let labels = [
            QuotaIndicator.accessibilityLabel(for: .green),
            QuotaIndicator.accessibilityLabel(for: .red),
            QuotaIndicator.accessibilityLabel(for: .grey),
        ]
        XCTAssertEqual(Set(labels).count, 3, "the three states must be distinguishable by ear too")
        for label in labels {
            XCTAssertTrue(label.contains("Glyphline"), "\(label) must name the app")
        }
    }

    func testARowShowsThePercentageAndTheResetInstant() {
        let window = RateWindow(
            kind: .rollingFiveHours,
            usedFraction: 0.62,
            resetAt: now.addingTimeInterval(3_600),
            observedAt: now
        )
        let reset = shortTime(now.addingTimeInterval(3_600))
        XCTAssertEqual(
            QuotaIndicator.rowText(for: window, now: now),
            "5h 62% — resets \(reset)",
            "the row must carry both the percentage and the reset instant its name promises"
        )
    }

    func testARowWithoutAFractionSaysSoRatherThanShowingZero() {
        let window = RateWindow(
            kind: .weekly,
            usedFraction: nil,
            resetAt: now.addingTimeInterval(3_600),
            observedAt: now
        )
        let text = QuotaIndicator.rowText(for: window, now: now)
        XCTAssertFalse(text.contains("0%"), "a missing fraction must not render as zero")
        // The negative alone would pass for an empty string. Pin what the branch
        // actually says, so the row stays useful rather than merely not wrong.
        XCTAssertEqual(
            text,
            "Week — usage unknown, resets \(shortTime(now.addingTimeInterval(3_600)))"
        )
    }
}
