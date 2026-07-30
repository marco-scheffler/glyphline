import XCTest
@testable import Glyphline

final class QuotaIndicatorTests: XCTestCase {
    /// UTC-anchored so every expected string below can be written out in full.
    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        ) ?? Date(timeIntervalSince1970: 0)
    }

    private let now = QuotaIndicatorTests.utc(2026, 7, 28, 9, 0)
    private let freshness: TimeInterval = 3_600

    /// Pinned rather than taken from the machine, so the expectations below are
    /// literal strings and not a second copy of the implementation's formatter.
    private let formatting = QuotaFormatting(
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: TimeZone(identifier: "UTC") ?? .gmt
    )

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
        windows: [QuotaWindowState],
        message: String? = nil
    ) -> QuotaAccountState {
        QuotaAccountState(
            accountID: UUID(),
            displayName: name,
            windows: windows,
            message: message
        )
    }

    /// Collapses the narrow and non-breaking spaces `DateFormatter` places around
    /// AM/PM into ordinary ones, so the expectations below can be written as
    /// visible literals. This normalises *whitespace only* — it does not rebuild
    /// the formatter, so a change of date style, order, or wording still fails.
    private func visible(_ text: String?) -> String? {
        text?
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// A window as the coordinator hands it over: the stored observation, plus
    /// the instant a fetch last confirmed the value. `confirmedMinutesAgo: nil`
    /// stands for a row read back before any fetch has run in this process.
    private func window(
        kind: RateWindowKind = .rollingFiveHours,
        used: Double?,
        observedMinutesAgo: Double = 0,
        confirmedMinutesAgo: Double? = nil,
        resetMinutesFromNow: Double = 30
    ) -> QuotaWindowState {
        QuotaWindowState(
            window: RateWindow(
                kind: kind,
                usedFraction: used,
                resetAt: now.addingTimeInterval(resetMinutesFromNow * 60),
                observedAt: now.addingTimeInterval(-observedMinutesAgo * 60)
            ),
            confirmedAt: confirmedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }
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
        XCTAssertEqual(
            visible(QuotaIndicator.nextFree(for: states, now: now, freshness: freshness, formatting: formatting)),
            "Max #2 — now"
        )
    }

    func testNextFreeNamesTheEarliestResetWhenAllAreExhausted() {
        // Distinct reset instants, so "earliest" is actually discriminated: an
        // implementation returning max(), or the first element, fails here.
        // `now` is 09:00 UTC, so +60 minutes is 10:00 and +180 is 12:00.
        let states = [
            account("Max #1", used: 1.0, resetMinutesFromNow: 180),
            account("Max #2", used: 1.0, resetMinutesFromNow: 60),
        ]
        XCTAssertEqual(
            visible(QuotaIndicator.nextFree(for: states, now: now, freshness: freshness, formatting: formatting)),
            "Max #2 — 10:00 AM"
        )
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
        XCTAssertEqual(
            visible(QuotaIndicator.nextFree(for: states, now: now, freshness: freshness, formatting: formatting)),
            "Max #1 — 11:00 AM"
        )
    }

    func testNextFreeIgnoresResetsThatHaveAlreadyElapsed() {
        // A window can be fresh and still carry a reset instant in the past.
        let states = [
            accountWith("Max #1", windows: [
                window(kind: .rollingFiveHours, used: 1.0, resetMinutesFromNow: 120),
                window(kind: .weekly, used: 1.0, resetMinutesFromNow: -15),
            ]),
        ]
        XCTAssertEqual(
            visible(QuotaIndicator.nextFree(for: states, now: now, freshness: freshness, formatting: formatting)),
            "Max #1 — 11:00 AM"
        )
    }

    /// The reset the header names can be days out — a weekly window resets days
    /// out by definition. "Max #1 — 2:00 PM" for a Friday reset read as today.
    func testNextFreeCarriesTheDateWhenTheResetIsNotToday() {
        let states = [
            accountWith("Max #1", windows: [
                window(kind: .weekly, used: 1.0, resetMinutesFromNow: 3 * 24 * 60 + 5 * 60),
            ]),
        ]
        XCTAssertEqual(
            visible(QuotaIndicator.nextFree(for: states, now: now, freshness: freshness, formatting: formatting)),
            "Max #1 — Jul 31, 2026 at 2:00 PM"
        )
    }

    /// The defect this pair exists for. A provider that keeps reporting the same
    /// figure produces no new row, so the stored `observedAt` stops moving — and
    /// freshness measured from it declared an actively confirmed reading unknown.
    /// A fixed reset with a stable fraction is exactly what an *idle* user has,
    /// and idle is when someone glances at the menu bar to ask "am I free yet?".
    func testAValueTheProviderKeepsConfirmingDoesNotAgeIntoUnknown() {
        let states = [
            accountWith("Max #1", windows: [
                window(used: 0.3, observedMinutesAgo: 120, confirmedMinutesAgo: 0.5),
            ]),
        ]

        XCTAssertEqual(QuotaIndicator.light(for: states, now: now, freshness: freshness), .green)
        XCTAssertEqual(
            visible(QuotaIndicator.nextFree(for: states, now: now, freshness: freshness, formatting: formatting)),
            "Max #1 — now"
        )
    }

    /// The converse, so the fix cannot degenerate into "always fresh": a
    /// confirmation is itself subject to the bound.
    func testAConfirmationOlderThanTheBoundDoesNotRescueAWindow() {
        let states = [
            accountWith("Max #1", windows: [
                window(used: 0.3, observedMinutesAgo: 120, confirmedMinutesAgo: 90),
            ]),
        ]

        XCTAssertEqual(QuotaIndicator.light(for: states, now: now, freshness: freshness), .grey)
        XCTAssertNil(QuotaIndicator.nextFree(for: states, now: now, freshness: freshness, formatting: formatting))
    }

    /// A row read back before any fetch has run still has to be judged, and
    /// `observedAt` is the best lower bound available for it.
    func testAnUnconfirmedWindowFallsBackToWhenItWasFirstSeen() {
        let recent = [accountWith("A", windows: [window(used: 0.3, observedMinutesAgo: 5)])]
        let ancient = [accountWith("A", windows: [window(used: 0.3, observedMinutesAgo: 5_000)])]

        XCTAssertEqual(QuotaIndicator.light(for: recent, now: now, freshness: freshness), .green)
        XCTAssertEqual(QuotaIndicator.light(for: ancient, now: now, freshness: freshness), .grey)
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
        XCTAssertEqual(
            visible(QuotaIndicator.rowText(for: window, now: now, formatting: formatting)),
            "5h 62% — resets 10:00 AM",
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
        let text = visible(QuotaIndicator.rowText(for: window, now: now, formatting: formatting)) ?? ""
        XCTAssertFalse(text.contains("0%"), "a missing fraction must not render as zero")
        // The negative alone would pass for an empty string. Pin what the branch
        // actually says, so the row stays useful rather than merely not wrong.
        XCTAssertEqual(text, "Week — usage unknown, resets 10:00 AM")
    }

    /// A weekly window resets days out. Rendered as a bare clock time it reads as
    /// today, which is a different claim than the one the app holds.
    func testAResetSeveralDaysOutCarriesItsDateAndNotJustAClockTime() {
        let window = RateWindow(
            kind: .weekly,
            usedFraction: 0.4,
            // 09:00 on the 28th plus three days and five hours: 14:00 on the 31st.
            resetAt: Self.utc(2026, 7, 31, 14, 0),
            observedAt: now
        )
        XCTAssertEqual(
            visible(QuotaIndicator.rowText(for: window, now: now, formatting: formatting)),
            "Week 40% — resets Jul 31, 2026 at 2:00 PM"
        )
    }

    /// The spike found a Codex subscription term ending in 2027. As a bare clock
    /// time that rendered "resets 09:00" — this morning, and a refill that never
    /// happens. A term end is neither today nor a reset.
    func testABillingCycleEndCarriesItsYearAndIsNotCalledAReset() {
        let window = RateWindow(
            kind: .billingCycle,
            usedFraction: nil,
            resetAt: Self.utc(2027, 3, 9, 9, 0),
            observedAt: now
        )
        let text = visible(QuotaIndicator.rowText(for: window, now: now, formatting: formatting)) ?? ""

        XCTAssertEqual(text, "Cycle — usage unknown, ends Mar 9, 2027 at 9:00 AM")
        XCTAssertFalse(
            text.contains("resets"),
            "a subscription term end returns no capacity, so it must not be called a reset"
        )
    }

    /// The fourth site the freshness rule had to reach, and the one it never did.
    /// The light greys, the header vanishes — and the row kept printing an exact
    /// percentage the app had formally decided not to believe.
    func testAStaleRowIsQualifiedRatherThanPrintedAsFact() {
        let states = [
            accountWith("Max #1", windows: [
                window(used: 0.62, observedMinutesAgo: 120, resetMinutesFromNow: 60),
            ]),
        ]
        let groups = QuotaIndicator.rowGroups(
            for: states, now: now, freshness: freshness, formatting: formatting
        )

        XCTAssertEqual(
            visible(groups.first?.rows.first),
            "5h 62% — resets 10:00 AM (as of 7:00 AM)"
        )
    }

    /// The counterpart: a fresh row carries no qualifier, so the "as of" stays a
    /// signal rather than decoration on every line.
    func testAFreshRowCarriesNoAsOfQualifier() {
        let states = [
            accountWith("Max #1", windows: [
                window(used: 0.62, observedMinutesAgo: 5, resetMinutesFromNow: 60),
            ]),
        ]
        let groups = QuotaIndicator.rowGroups(
            for: states, now: now, freshness: freshness, formatting: formatting
        )

        XCTAssertEqual(visible(groups.first?.rows.first), "5h 62% — resets 10:00 AM")
    }

    /// The rows must obey the same bound as the light, judged on the same data.
    /// A window the light believes and a row that qualifies it — or the reverse —
    /// is the disagreement this feature kept reintroducing.
    func testTheRowsAndTheLightAgreeAboutTheSameWindow() {
        let confirmed = [
            accountWith("Max #1", windows: [
                window(used: 0.62, observedMinutesAgo: 120, confirmedMinutesAgo: 1, resetMinutesFromNow: 60),
            ]),
        ]

        XCTAssertEqual(QuotaIndicator.light(for: confirmed, now: now, freshness: freshness), .green)
        XCTAssertEqual(
            visible(
                QuotaIndicator.rowGroups(
                    for: confirmed, now: now, freshness: freshness, formatting: formatting
                ).first?.rows.first
            ),
            "5h 62% — resets 10:00 AM",
            "the light believes this window, so the row must not qualify it"
        )
    }

    /// An account with no quota source always carries a message, and the menu
    /// used to render the message *or* the windows. Its billing cycle — the only
    /// genuine quota datum this branch can produce for a real user — was
    /// therefore never drawn.
    func testAnAccountWithAMessageStillShowsTheWindowsItDoesHave() {
        let states = [
            accountWith(
                "Max #1",
                windows: [window(kind: .billingCycle, used: nil, resetMinutesFromNow: 60)],
                message: RateWindowSourceError.notAvailable.message
            ),
        ]
        let group = QuotaIndicator.rowGroups(
            for: states, now: now, freshness: freshness, formatting: formatting
        ).first

        XCTAssertEqual(group?.message, RateWindowSourceError.notAvailable.message)
        XCTAssertEqual(
            visible(group?.rows.first),
            "Cycle — usage unknown, ends 10:00 AM",
            "the reason the short windows are missing is not a reason to hide the cycle"
        )
    }

    /// The counterpart to the two above: a five-hour window resetting today must
    /// *not* acquire a date, or every row grows a redundant "Jul 28, 2026".
    func testAResetLaterTodayStaysAPlainClockTime() {
        let window = RateWindow(
            kind: .rollingFiveHours,
            usedFraction: 0.5,
            resetAt: Self.utc(2026, 7, 28, 23, 30),
            observedAt: now
        )
        XCTAssertEqual(
            visible(QuotaIndicator.rowText(for: window, now: now, formatting: formatting)),
            "5h 50% — resets 11:30 PM"
        )
    }

    // MARK: - Structured rows

    /// A window built relative to a caller-supplied `now`, so the helpers below
    /// can be anchored to the instant the test under them uses rather than to
    /// this class's fixed `now`.
    private func windowState(
        kind: RateWindowKind,
        used: Double?,
        now: Date,
        ageSeconds: TimeInterval
    ) -> QuotaWindowState {
        QuotaWindowState(
            window: RateWindow(
                kind: kind,
                usedFraction: used,
                resetAt: now.addingTimeInterval(3_600),
                observedAt: now.addingTimeInterval(-ageSeconds)
            ),
            confirmedAt: now.addingTimeInterval(-ageSeconds)
        )
    }

    /// Every window comfortably inside the bound.
    private func freshStates(now: Date, bound: TimeInterval = 3_600) -> [QuotaAccountState] {
        [
            accountWith("Max #1", windows: [
                windowState(kind: .rollingFiveHours, used: 0.62, now: now, ageSeconds: bound / 4),
                windowState(kind: .weekly, used: 0.2, now: now, ageSeconds: bound / 4),
            ]),
            accountWith("Max #2", windows: [
                windowState(kind: .billingCycle, used: nil, now: now, ageSeconds: bound / 4),
            ]),
        ]
    }

    /// Every window past the bound: `believableSince` is `bound * 2` old, and
    /// `isFresh` compares against `bound`.
    private func staleStates(now: Date, bound: TimeInterval = 3_600) -> [QuotaAccountState] {
        [
            accountWith("Max #1", windows: [
                windowState(kind: .rollingFiveHours, used: 0.62, now: now, ageSeconds: bound * 2),
                windowState(kind: .weekly, used: nil, now: now, ageSeconds: bound * 2),
            ]),
            accountWith("Max #2", windows: [
                windowState(kind: .billingCycle, used: 0.9, now: now, ageSeconds: bound * 2),
            ]),
        ]
    }

    /// One of each on the same account, so a bug that treats a whole account
    /// uniformly cannot pass.
    private func mixedStates(now: Date, bound: TimeInterval = 3_600) -> [QuotaAccountState] {
        [
            accountWith("Max #1", windows: [
                windowState(kind: .rollingFiveHours, used: 0.62, now: now, ageSeconds: bound / 4),
                windowState(kind: .weekly, used: 0.4, now: now, ageSeconds: bound * 2),
            ]),
        ]
    }

    /// The helpers above are the premise of the binding test: a "stale" helper
    /// that is really fresh would make it vacuous. Pin the verdicts directly.
    func testTheFreshnessHelpersProduceTheVerdictsTheirNamesClaim() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bound: TimeInterval = 3_600

        func verdicts(_ states: [QuotaAccountState]) -> [Bool] {
            states.flatMap(\.windows).map {
                QuotaIndicator.isFresh($0, now: now, freshness: bound)
            }
        }

        XCTAssertEqual(verdicts(freshStates(now: now)), [true, true, true])
        XCTAssertEqual(verdicts(staleStates(now: now)), [false, false, false])
        XCTAssertEqual(verdicts(mixedStates(now: now)), [true, false])
    }

    /// The binding test. `barGroups` and `rowGroups` must reach the SAME freshness
    /// verdict for every row: `asOf` is non-nil exactly where `rowGroups` appends
    /// its "(as of …)" qualifier. Asserting equal row COUNTS would pass trivially —
    /// neither accessor drops a stale row — so the verdict is the thing to pin.
    func testTheTwoAccessorsAgreeOnFreshness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let freshness: TimeInterval = 3_600

        // Fresh, stale, and one of each in the same account.
        for states in [freshStates(now: now), staleStates(now: now), mixedStates(now: now)] {
            let bars = QuotaIndicator.barGroups(for: states, now: now, freshness: freshness)
            let rows = QuotaIndicator.rowGroups(for: states, now: now, freshness: freshness)

            XCTAssertEqual(bars.count, rows.count)
            for (barGroup, rowGroup) in zip(bars, rows) {
                XCTAssertEqual(barGroup.rows.count, rowGroup.rows.count)
                for (bar, row) in zip(barGroup.rows, rowGroup.rows) {
                    XCTAssertEqual(
                        bar.asOf != nil,
                        row.contains("(as of "),
                        "freshness verdicts disagree for \(bar.label): bar asOf=\(String(describing: bar.asOf)), row=\(row)"
                    )
                }
            }
        }
    }

    /// A provider that reports a reset instant but no consumed fraction must not
    /// render as 0% — that is a wrong number, not a missing one.
    func testAMissingFractionIsNotZero() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = QuotaAccountState(
            accountID: UUID(),
            displayName: "Max #1",
            windows: [
                QuotaWindowState(
                    window: RateWindow(
                        kind: .rollingFiveHours,
                        usedFraction: nil,
                        resetAt: now.addingTimeInterval(3_600),
                        observedAt: now
                    ),
                    confirmedAt: now
                )
            ],
            message: nil
        )

        let row = QuotaIndicator.barGroups(for: [state], now: now, freshness: 3_600).first?.rows.first
        XCTAssertNil(row?.fraction)
        XCTAssertFalse(row?.detail.contains("0%") ?? true)
    }

    /// The cycle says "ends", not "resets" — a term end returns no capacity. Both
    /// surfaces must say the same thing, which is why the switch is shared.
    func testTheCycleEndsRatherThanResets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = QuotaAccountState(
            accountID: UUID(),
            displayName: "Max #1",
            windows: [
                QuotaWindowState(
                    window: RateWindow(
                        kind: .billingCycle,
                        usedFraction: nil,
                        resetAt: now.addingTimeInterval(86_400),
                        observedAt: now
                    ),
                    confirmedAt: now
                )
            ],
            message: nil
        )

        let row = QuotaIndicator.barGroups(for: [state], now: now, freshness: 3_600).first?.rows.first
        XCTAssertEqual(row?.label, "Cycle")
        XCTAssertTrue(row?.detail.contains("ends") ?? false)
        XCTAssertFalse(row?.detail.contains("resets") ?? true)
    }

    /// The group carries the account's message through unchanged — the card shows
    /// it instead of bars, so a dropped message means an account fails silently.
    func testTheGroupCarriesTheAccountMessage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = QuotaAccountState(
            accountID: UUID(),
            displayName: "Max #1",
            windows: [],
            message: RateWindowSourceError.sessionExpired.message
        )

        let group = QuotaIndicator.barGroups(for: [state], now: now, freshness: 3_600).first
        XCTAssertEqual(group?.message, RateWindowSourceError.sessionExpired.message)
        XCTAssertTrue(group?.rows.isEmpty ?? false)
    }
}
