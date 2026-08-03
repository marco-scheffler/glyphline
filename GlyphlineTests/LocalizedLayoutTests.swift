import AppKit
import SwiftUI
import XCTest

@testable import Glyphline

/// Every layout in this app was sized against English, and then the app was
/// translated into seven more languages without anybody measuring one of them.
/// This file measures them.
///
/// **How a language other than English gets rendered here, and why the numbers
/// are the real ones.** The test scheme is pinned to `en` (`scheme.language: en`
/// in `project.yml`) so that the suite's assertions on English sentences stay
/// stable, and that pin must not be lifted. There are two kinds of string in
/// this app and they need two different techniques, because they resolve through
/// two different mechanisms:
///
/// 1. `Text("Refresh")` in a view takes a `LocalizedStringKey` and SwiftUI
///    resolves it *at layout time*, against `\.locale` in the environment. So
///    `.environment(\.locale, Locale(identifier: "de"))` on a hosting view makes
///    SwiftUI do the same bundle lookup it does on a German Mac, with the same
///    fonts and the same layout engine. `testTheLocaleOverrideActuallyReaches
///    TheRender` is the guard that this is true and keeps being true — a
///    measurement that silently stayed English would be worse than none.
///
/// 2. `String(localized:)` in a *model* resolves against `Bundle.main` and the
///    process's language, which the pin fixes at English and which no
///    environment can move. For those the technique is to read the value out of
///    the compiled `<lang>.lproj/Localizable.strings` in the built bundle — the
///    exact table and the exact value the app reads on that Mac — and to render
///    it with the same font, control and constraints the production view uses.
///
/// Both are hosted in an off-screen `NSHostingView` with the activation policy
/// left at `.prohibited`: nothing appears on screen and no GUI is driven.
@MainActor
final class LocalizedLayoutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// Every language the catalog ships, English included — English is a
    /// measurement too, and twice below it is the one that turned out to be
    /// tightest.
    private static let languages = ["en"] + LocalizationTests.translatedLanguages

    /// Any lighting at all: the sign's room is a function of the projection and
    /// nothing here reads a colour.
    private static let lighting = OfficeLighting.at(
        date: Date(timeIntervalSince1970: 1_800_000_000),
        place: UserPlace.Coordinates(latitude: 52.52, longitude: 13.405, source: .table),
        weather: .clear
    )

    /// One compiled table out of the built bundle. Same source as
    /// `LocalizationTests`: the *bundle*, not the `.xcstrings`, because a
    /// language present in the catalog but missing from the build is a different
    /// failure and not this file's.
    private func table(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "Localizable",
                            withExtension: "strings",
                            subdirectory: "\(language).lproj"),
            "\(language) never reached the app bundle"
        )
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    private func translation(of key: String, in language: String) throws -> String {
        let table = try table(language)
        return try XCTUnwrap(table[key], "\(language) has no translation for \(key)")
    }

    /// What a view lays out to in one language.
    private func width(of view: some View, in language: String) -> CGFloat {
        let host = NSHostingView(
            rootView: AnyView(view.environment(\.locale, Locale(identifier: language)))
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    // MARK: - The technique itself

    /// The load-bearing assumption of technique (1), asserted rather than
    /// assumed.
    ///
    /// If SwiftUI ever stopped resolving `LocalizedStringKey` against the
    /// environment's locale — or if the override were written wrongly — every
    /// measurement below would quietly become eight measurements of English,
    /// all passing, all meaningless. That is the specific failure this file
    /// cannot afford, so it is named.
    ///
    /// Would catch: dropping `.environment(\.locale, …)` from `width(of:in:)`.
    /// Doing so gives 51 for all three.
    func testTheLocaleOverrideActuallyReachesTheRender() throws {
        let english = width(of: Text("Settings"), in: "en")
        let german = width(of: Text("Settings"), in: "de")
        let japanese = width(of: Text("Settings"), in: "ja")

        // "Einstellungen" against "Settings" — no font metric makes those the
        // same width.
        XCTAssertGreaterThan(german, english * 1.4,
                             "the German render measured \(german) against English's \(english)")
        XCTAssertLessThan(japanese, english,
                          "the Japanese render measured \(japanese) against English's \(english)")
        // And the string really is the catalog's, not a lucky font difference.
        XCTAssertEqual(try translation(of: "Settings", in: "de"), "Einstellungen")
    }

    // MARK: - The menu bar panel

    /// The panel is a fixed 320 points and clips whatever does not fit, from the
    /// trailing edge, without a word. `MenuBarFooterTests` holds that in
    /// English; this holds it in the seven languages the app was translated into
    /// and nobody measured.
    ///
    /// The translator chose "Neu laden" over "Aktualisieren" for `Refresh`
    /// specifically to protect this row, on judgement rather than on a
    /// measurement. The judgement was right and the row was never in danger.
    ///
    /// The row is three equal columns now, so what it costs is three times the
    /// widest single label rather than the sum of five natural widths. German is
    /// the widest at 268 against the 296 available, 28 points clear.
    ///
    /// Which changes what would break it, and makes this test load-bearing rather
    /// than reassuring: a label only has to be the widest *one* to set all three
    /// columns, so a single long word now costs three times what it used to. The
    /// translator's caution over `Refresh` applies to every label in the row now,
    /// not just to the one that shared a line with `Quit`.
    ///
    /// Would catch: a translation long enough to overflow. Putting
    /// "Aktualisieren" in `Refresh`'s place is not enough on its own — that row
    /// is `Refresh`, a spacer and `Quit` — but moving `SettingsLink` down beside
    /// it, or a sixth control, is, and so is any language whose three top-row
    /// words outgrow the panel.
    func testTheFooterFitsThePanelInEveryLanguage() {
        let available = MenuBarView.panelWidth - 2 * MenuBarView.panelPadding
        for language in Self.languages {
            let measured = width(
                of: MenuBarFooter(openDashboard: {}, openAgentverse: {}, refresh: {}),
                in: language
            )
            XCTAssertGreaterThan(measured, 0, "\(language) laid out to nothing")
            XCTAssertLessThanOrEqual(
                measured, available,
                "the footer measures \(measured) in \(language), against the panel's \(available)"
            )
        }
    }

    // MARK: - The quota row's label gutter

    /// The wide quota row gives the window's name a fixed gutter so that two
    /// stacked bars start on the same line. The gutter was 52 points, which is
    /// what English needs — "Cycle" is 33 — and a `frame(width:)` narrower than
    /// its text does not complain, it truncates.
    ///
    /// Italian's "Settimana" measures 59. Against 52 the dashboard card was
    /// printing "Settiman…" beside every weekly bar.
    ///
    /// The names come from `String(localized:)` in `RateWindowKind`, so this
    /// uses technique (2): the value out of the compiled table, rendered in the
    /// font and weight `QuotaBarRowView.wideBody` gives it.
    ///
    /// Would catch: `labelColumnWidth` going back to 52 — Italian fails at 59.
    func testEveryWindowNameFitsTheQuotaRowsLabelGutter() throws {
        // The three keys `RateWindowKind.shortName` resolves, in its own order.
        let keys = ["5h", "quotaWindow.weekly.short", "Cycle"]
        for language in Self.languages {
            for key in keys {
                let name = try translation(of: key, in: language)
                let measured = width(
                    of: Text(verbatim: name).font(.callout.weight(.medium)),
                    in: language
                )
                XCTAssertLessThanOrEqual(
                    measured, QuotaBarRowView.labelColumnWidth,
                    """
                    \(language)'s "\(name)" measures \(measured) in a \
                    \(QuotaBarRowView.labelColumnWidth)-point gutter and is truncated
                    """
                )
            }
        }
    }

    /// The English source strings themselves, so the keys above stay the ones
    /// `RateWindowKind` actually asks for. A renamed key would otherwise make
    /// the test above unwrap nothing and fail for the wrong reason — or, worse,
    /// keep measuring a name the app no longer draws.
    func testTheGutterIsMeasuredAgainstTheNamesTheRowActuallyDraws() {
        XCTAssertEqual(RateWindowKind.allCases.map(\.shortName), ["5h", "Week", "Cycle"])
    }

    // MARK: - The chart's period picker

    /// A segmented control truncates its segments when it is given less width
    /// than it asks for, and reports nothing. This one was pinned to 220 points,
    /// measured once against English — which wants 221, so even English was
    /// being squeezed — while Italian wants 234.
    ///
    /// The titles come from `String(localized:)`, so they are injected from the
    /// compiled table rather than resolved from the environment; everything else
    /// about the control is production's.
    ///
    /// Would catch: `.fixedSize()` going back to `.frame(width: 220)`. English
    /// fails first, at 221 against 220, and Italian by 14 points.
    func testThePeriodPickerGetsTheWidthItsSegmentsAskFor() throws {
        for language in Self.languages {
            let table = try table(language)
            let titles: (LocalUsagePeriod) -> String = { period in
                table[period.title] ?? period.title
            }
            let production = width(
                of: ChartPeriodPicker(period: .constant(.last7Days), title: titles),
                in: language
            )
            // What the same three segments want when nothing constrains them.
            let wanted = width(
                of: Picker("Period", selection: .constant(LocalUsagePeriod.last7Days)) {
                    ForEach(LocalUsagePeriod.allCases) { period in
                        Text(verbatim: titles(period)).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden(),
                in: language
            )

            XCTAssertGreaterThan(wanted, 0, "\(language) laid out to nothing")
            XCTAssertGreaterThanOrEqual(
                production, wanted,
                "the picker is laid out at \(production) in \(language) and wants \(wanted)"
            )
        }
    }

    // MARK: - The Agentverse's painted signs

    /// The office scene's signs are drawn into a `Canvas`, which clips nothing
    /// and reports nothing: an overlong string simply runs out of the thing it
    /// names and across whatever is beside it.
    ///
    /// In the tightest scene this app lays out — 24 sessions in a 900×600 pane —
    /// the room is 78 points wide where the sign hangs, and "BREAK ROOM" is 60,
    /// which is why it read as settled. Spanish and Portuguese "SALA DE
    /// DESCANSO" is 91.
    ///
    /// Measured with `NSHostingView` rather than with a `GraphicsContext`: both
    /// go through the same text engine with the same font, and a canvas cannot
    /// be resolved outside a render pass. The production fit uses the context's
    /// own `measure`, so the two agree to within rounding — which is why the
    /// assertion below is on the *fitted* string and not on a raw number.
    ///
    /// Would catch: the sign going back to an unfitted `Text("BREAK ROOM")`.
    /// Then Spanish comes back whole at 91 in a 78-point room. The second half
    /// catches the opposite mistake — a fitter that cuts everything to nothing
    /// would satisfy the bound and pass on its own.
    func testTheBreakRoomSignIsCutToTheRoomInEveryLanguage() throws {
        // The tightest room the app lays out: a small window full of sessions.
        let renderer = OfficeRenderer(
            layout: IsoLayout.fit(sessionCount: 24, canvas: CGSize(width: 900, height: 600)),
            frame: 0,
            hovered: nil,
            lighting: Self.lighting
        )
        let available = renderer.signAvailableWidth
        XCTAssertGreaterThan(available, 0)

        for language in Self.languages {
            let sign = try translation(of: "BREAK ROOM", in: language)
            let measure: (String) -> Double = { string in
                Double(self.width(of: renderer.signText(string), in: language))
            }
            let fitted = renderer.fittedBreakRoomSign(sign, measure: measure)

            XCTAssertLessThanOrEqual(
                measure(fitted), available,
                "\(language)'s \"\(sign)\" still measures \(measure(fitted)) in \(available)"
            )
            XCTAssertFalse(fitted.isEmpty, "\(language) lost the sign entirely")

            // The five that fit are handed back whole. Only Spanish and
            // Portuguese are over at this size.
            if !["es", "pt-BR"].contains(language) {
                XCTAssertEqual(fitted, sign, "\(language) was cut and did not need to be")
            }
        }
    }

    /// The break room sign's room is a function of the pane and of how many
    /// desks are in it — which is exactly why it cannot be a character count.
    ///
    /// Would catch: `signAvailableWidth` becoming a constant. The two panes
    /// below differ by 40 points at eight sessions.
    func testTheBreakRoomSignsRoomFollowsTheScene() {
        func available(sessions: Int, canvas: CGSize) -> Double {
            OfficeRenderer(layout: IsoLayout.fit(sessionCount: sessions, canvas: canvas),
                           frame: 0, hovered: nil, lighting: Self.lighting).signAvailableWidth
        }
        let wide = available(sessions: 8, canvas: CGSize(width: 1300, height: 740))
        let narrow = available(sessions: 8, canvas: CGSize(width: 900, height: 600))
        let crowded = available(sessions: 24, canvas: CGSize(width: 900, height: 600))

        XCTAssertGreaterThan(wide, narrow + 40, "\(wide) against \(narrow)")
        XCTAssertGreaterThan(narrow, crowded, "\(narrow) against \(crowded)")
    }

    /// The "off the clock" heading shares its line with the first sleeper's
    /// head, and has to stop short of it. English is 81 against the 89 it may
    /// have; Spanish is 99 and Portuguese 109, both of which would be drawn
    /// across a face.
    ///
    /// Would catch: `fittedOffClockHeading` returning its argument. Portuguese
    /// then measures 109 against 89.
    func testTheOffClockHeadingStopsShortOfTheFirstSleeper() throws {
        for language in Self.languages {
            let heading = try translation(of: "OFF THE CLOCK", in: language)
            let measure: (String) -> Double = { string in
                Double(self.width(of: OfficeRenderer.offClockHeadingText(string), in: language))
            }
            let fitted = OfficeRenderer.fittedOffClockHeading(heading, measure: measure)

            XCTAssertLessThanOrEqual(measure(fitted), OfficeRenderer.offClockHeadingWidth,
                                     "\(language): \"\(fitted)\" is \(measure(fitted))")
            XCTAssertFalse(fitted.isEmpty, "\(language) lost the heading entirely")
        }
        // And the six languages that fit are left alone rather than all being
        // cut to a common length — the point of fitting by width.
        for language in ["en", "de", "fr", "it", "ja", "zh-Hans"] {
            let heading = try translation(of: "OFF THE CLOCK", in: language)
            let fitted = OfficeRenderer.fittedOffClockHeading(heading) { string in
                Double(self.width(of: OfficeRenderer.offClockHeadingText(string), in: language))
            }
            XCTAssertEqual(fitted, heading, "\(language) was cut and did not need to be")
        }
    }

    /// The datastream's "waiting on you" plate is `min(laneWidth - 16, 150)`
    /// wide — a variable, because a lane is the pane divided by however many
    /// sessions are open. The sign was drawn into it unfitted.
    ///
    /// This one was already wrong in English: at ten lanes the plate is 114
    /// points, the sign is 99, and the two 8-point insets leave 98. German's
    /// "▲ WARTET AUF DICH" is 106 and overruns the plate from six lanes on.
    ///
    /// Would catch: `fittedWaitingBanner` returning its argument, or the inset
    /// being dropped.
    func testTheWaitingBannerIsCutToItsPlateInEveryLanguage() throws {
        let pane = CGSize(width: 1300, height: 740)
        for lanes in [2, 6, 10, 16] {
            let plate = min(DatastreamLayout(canvas: pane, laneCount: lanes).laneWidth - 16, 150)
            for language in Self.languages {
                let sign = try translation(of: "▲ WAITING ON YOU", in: language)
                let measure: (String) -> Double = { string in
                    Double(self.width(of: DatastreamRenderer.waitingBannerText(string),
                                      in: language))
                }
                let fitted = DatastreamRenderer.fittedWaitingBanner(
                    sign, plateWidth: plate, measure: measure
                )
                XCTAssertLessThanOrEqual(
                    measure(fitted), plate - 2 * DatastreamRenderer.waitingBannerInset,
                    "\(lanes) lanes, \(language): \"\(fitted)\" is \(measure(fitted)) in \(plate)"
                )
            }
        }
        // Two lanes is a wide plate and nothing should be cut there — a fitter
        // that truncated everything would pass the bound above.
        let widePlate = min(DatastreamLayout(canvas: pane, laneCount: 2).laneWidth - 16, 150)
        for language in Self.languages {
            let sign = try translation(of: "▲ WAITING ON YOU", in: language)
            let fitted = DatastreamRenderer.fittedWaitingBanner(
                sign, plateWidth: widePlate
            ) { Double(self.width(of: DatastreamRenderer.waitingBannerText($0), in: language)) }
            XCTAssertEqual(fitted, sign, "\(language) was cut on a 150-point plate")
        }
    }
}
