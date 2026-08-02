import XCTest
@testable import Glyphline

/// The load-bearing facts about this app's localisation that nothing else in the
/// suite would notice going wrong.
///
/// Every other assertion on a rendered sentence — "on track", "5h 62% — resets
/// 10:00 AM", "+38 % vs. 7-day median" — now travels through the String Catalog
/// rather than through a literal in the source. That makes those assertions
/// depend on two things they never used to: the language the *test process* is
/// running in, and the catalog actually reaching the bundle. Neither is visible
/// in a diff, and both fail in a way that looks like a wording bug rather than a
/// configuration one. So each gets a test that names it.
final class LocalizationTests: XCTestCase {
    /// Nothing in the app should be found under a key that is missing.
    private let sentinel = "__not-in-the-catalog__"

    private func catalogValue(for key: String) -> String? {
        let resolved = Bundle.main.localizedString(forKey: key, value: sentinel, table: nil)
        return resolved == sentinel ? nil : resolved
    }

    // MARK: - The language the suite runs in

    /// The suite is pinned to English by the scheme's test action
    /// (`scheme.language: en` in `project.yml`, which becomes `-AppleLanguages
    /// (en)` for the test process).
    ///
    /// Without that pin every assertion on an English sentence in this suite is
    /// really an assertion about the machine it runs on. This project's own Mac
    /// is set to German — `Locale.preferredLanguages` there is `["de-US"]` — so
    /// the day the catalog gains a German translation, a suite without the pin
    /// starts failing in dozens of places for a reason none of those failures
    /// names. Deleting the pin fails *this* test, which does name it.
    func testTheTestProcessIsPinnedToEnglish() {
        let first = Locale.preferredLanguages.first ?? ""
        XCTAssertTrue(
            first == "en" || first.hasPrefix("en-"),
            """
            The test process is running in "\(first)", not English. \
            Every assertion in this suite that names an English sentence is \
            unreliable until the scheme's test language is pinned again.
            """
        )
    }

    // The other half of the pin — that the *region* was not forced along with
    // the language — has no test here, deliberately. Numerals and dates must
    // keep following the machine, but every assertion in this suite that names
    // a number or a date builds its expected value with `.formatted()`, which
    // would follow a forced region too. There is no seam: a test written for it
    // would pass whether or not the region were pinned. The protection is the
    // comment on `scheme.language` in project.yml, and this sentence.

    // MARK: - The catalog reaching the bundle

    /// A String Catalog that is in the repository but not in the target's
    /// resources phase localises nothing, builds cleanly, and looks perfectly
    /// fine in the source tree — every English string keeps rendering, because
    /// `String(localized:)` falls back to the key. This is the one assertion
    /// that can tell the two apart.
    func testTheStringCatalogShipsInTheAppBundle() {
        XCTAssertNotNil(
            Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj"),
            "the compiled English table is missing from the bundle — the catalog is not in the resources phase"
        )
    }

    /// And that the app's own strings are actually being *read* from it rather
    /// than falling back to their keys.
    func testTheQuotaWordingResolvesThroughTheCatalog() {
        XCTAssertEqual(catalogValue(for: "on track"), "on track")
        XCTAssertEqual(catalogValue(for: "no active window"), "no active window")
        XCTAssertEqual(catalogValue(for: "empty in %@"), "empty in %@")
    }

    // MARK: - What must never become translatable

    /// Model identifiers are lookup keys. Translated, `modelDisplayName` misses
    /// in every language but English and the chart starts reciting raw
    /// identifiers at readers who are the least equipped to recognise them.
    func testModelIdentifiersAreNotCatalogKeys() {
        for identifier in ["claude-opus-5", "claude-haiku-4-5", "gpt-5.4"] {
            XCTAssertNil(catalogValue(for: identifier), "\(identifier) must not be translatable")
        }
    }

    /// The names derived from those identifiers are product names. "Opus 5" is
    /// called that in Berlin too, and a translated one would stop matching what
    /// the reader sees in the provider's own tooling.
    func testModelDisplayNamesAreNotCatalogKeys() {
        for name in ["Opus 5", "Haiku 4.5", "Sonnet 4.6", "GPT-5.4"] {
            XCTAssertNil(catalogValue(for: name), "\(name) is a product name and must not be translatable")
        }
        XCTAssertEqual(DashboardPresentation.modelDisplayName("claude-opus-5"), "Opus 5")
    }

    /// Provider names, likewise.
    func testProviderNamesAreNotCatalogKeys() {
        for provider in ProviderID.allCases {
            XCTAssertNil(
                catalogValue(for: provider.displayName),
                "\(provider.displayName) is a provider's own name and must not be translatable"
            )
        }
    }

    /// An SF Symbol name is an identifier the system resolves. Translated, the
    /// menu bar item renders nothing at all and reports no error — a failure
    /// that looks exactly like the app not running.
    func testTheMenuBarSymbolNameIsNotACatalogKey() {
        XCTAssertNil(catalogValue(for: QuotaIndicator.menuBarSymbolName))
    }

    /// The window kinds' raw values are persisted in the ledger and used as row
    /// identities. A translated one would not match a row written yesterday.
    func testRateWindowRawValuesAreNotCatalogKeys() {
        for kind in RateWindowKind.allCases {
            XCTAssertNil(catalogValue(for: kind.rawValue), "\(kind.rawValue) is persisted and must not be translatable")
            // The names beside them are prose and deliberately *are* in the
            // catalog, so the two cannot be confused for one another.
            XCTAssertNotNil(catalogValue(for: kind.shortName))
            XCTAssertNotNil(catalogValue(for: kind.longName))
        }
    }

    // MARK: - The views' own literals

    /// SwiftUI's `Text("…")` takes a `LocalizedStringKey`, so the roughly thirty
    /// literals across `Glyphline/UI` needed no code change at all — but that is
    /// only half the claim. The other half is that they were *extracted* into
    /// the catalog and reached the bundle, which is the part that can silently
    /// not happen.
    ///
    /// A sample from four different views rather than one: a single key could
    /// have been typed into the catalog by hand.
    func testTheViewsOwnLiteralsReachedTheCatalog() {
        for key in [
            "Dashboard",                                    // DashboardView
            "Open Settings",                                // DashboardView
            "No accounts yet. Open the dashboard to add one.", // MenuBarView
            "Glyphline also syncs after the Mac wakes from sleep.", // SettingsView
            "Rename Account",                               // AccountsView
            "No agent is running",                          // AgentverseWindow
        ] {
            XCTAssertNotNil(catalogValue(for: key), "\(key) never reached the catalog")
        }
    }

    // What this file does NOT assert, and why.
    //
    // That `unknownModelLabel` and `otherModelsLabel` still work as the chart's
    // series keys once they are localised. Both are drawn in the legend and used
    // as the key for the rows they stand for, which is worth a test — but in an
    // English-only build the localised value equals the literal, so replacing
    // either constant with its own bare literal leaves every assertion green.
    // That mutant was written and it survived, so the test went rather than
    // stay as a tautology. It becomes writable the day a second language lands.
    //
    // That SwiftUI actually performs the lookup at render time. There is no
    // view host in this suite to read a rendered `Text` back out of; the
    // extraction above is the part that could realistically be wrong.
}
