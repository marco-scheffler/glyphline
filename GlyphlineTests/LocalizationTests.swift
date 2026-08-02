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

    // MARK: - The seven translations

    /// The languages the catalog ships, beside the English source.
    static let translatedLanguages = ["de", "es", "fr", "it", "zh-Hans", "ja", "pt-BR"]

    /// One compiled table out of the built app bundle.
    ///
    /// Read from the *bundle* and not from `Localizable.xcstrings`, because the
    /// catalog is a source file: a language present in it but missing from the
    /// build — an unlisted region, a resources phase that dropped it — is
    /// precisely the failure a test reading the source could not see.
    private func compiledTable(for language: String) throws -> [String: String] {
        let url = try XCTUnwrap(
            Bundle.main.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: "\(language).lproj"
            ),
            "\(language) never reached the app bundle"
        )
        return try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "\(language).lproj/Localizable.strings did not parse as a string table"
        )
    }

    /// Every key, in every shipped language.
    ///
    /// A missing key is the quiet failure this whole file exists for: the
    /// lookup falls back to the English source string, renders perfectly, and
    /// says nothing. On a German Mac that is one English sentence in the middle
    /// of a German panel, and it reaches a user rather than a build log.
    func testEveryKeyIsTranslatedInEveryShippedLanguage() throws {
        let english = try compiledTable(for: "en")
        XCTAssertGreaterThan(english.count, 150, "the English table looks truncated")

        for language in Self.translatedLanguages {
            let table = try compiledTable(for: language)
            let missing = Set(english.keys).subtracting(table.keys).sorted()
            XCTAssertEqual(missing, [], "\(language) is missing \(missing.count) key(s)")
            let extra = Set(table.keys).subtracting(english.keys).sorted()
            XCTAssertEqual(extra, [], "\(language) carries \(extra.count) key(s) English does not")
            for (key, value) in table where value.trimmingCharacters(in: .whitespaces).isEmpty {
                XCTFail("\(language) has an empty translation for \(key)")
            }
        }
    }

    /// The format specifiers must survive translation, in kind and in count.
    ///
    /// This is the one localisation defect that is not a wording problem: a
    /// `%@` translated away, or an `%lld` that became a `%@`, makes
    /// `String(format:)` read an argument that is not there. That is a crash in
    /// one language and no other, on a machine the author does not own.
    func testEveryTranslationKeepsTheFormatSpecifiersOfItsSource() throws {
        let english = try compiledTable(for: "en")

        for language in Self.translatedLanguages {
            let table = try compiledTable(for: language)
            for (key, source) in english {
                guard let translated = table[key] else { continue }
                XCTAssertEqual(
                    Self.specifiers(in: translated),
                    Self.specifiers(in: source),
                    "\(language) changed the specifiers of \(key): \(translated)"
                )
            }
        }
    }

    /// Every `%…` conversion in a string, sorted, with any positional index
    /// (`%2$@`) dropped — reordering the arguments is exactly what a translator
    /// is *supposed* to be able to do. `%%` is a literal percent sign and counts
    /// as itself, so a language that drops one is caught too.
    private static func specifiers(in value: String) -> [String] {
        var found: [String] = []
        var rest = Substring(value)
        while let percent = rest.firstIndex(of: "%") {
            var index = rest.index(after: percent)
            while index < rest.endIndex, rest[index].isNumber || rest[index] == "$" {
                index = rest.index(after: index)
            }
            guard index < rest.endIndex else { break }
            if rest[index] == "l" {
                // `%lld` — the only length modifier this app uses.
                var end = index
                while end < rest.endIndex, rest[end] == "l" { end = rest.index(after: end) }
                if end < rest.endIndex, rest[end] == "d" {
                    found.append("%lld")
                    rest = rest[rest.index(after: end)...]
                    continue
                }
            }
            found.append("%\(rest[index])")
            rest = rest[rest.index(after: index)...]
        }
        return found.sorted()
    }

    /// Names that are not words.
    ///
    /// A translated "Glyphline" or "claude.ai" stops naming the thing it names;
    /// a translated "Claude Code" stops matching the tool the reader has
    /// installed. These sit *inside* translated sentences, so the guard has to
    /// be on the value rather than on the key — the key-level guards above
    /// cannot see them.
    func testProductNamesSurviveInsideTranslatedSentences() throws {
        let carriers: [String: String] = [
            "Glyphline — quota exhausted": "Glyphline",
            "Glyphline also syncs after the Mac wakes from sleep.": "Glyphline",
            "Its claude.ai sign-in will be removed from this Mac.": "claude.ai",
            "Local Claude Code logs": "Claude Code",
            "Open the Agentverse in its own window": "Agentverse",
        ]

        for language in Self.translatedLanguages {
            let table = try compiledTable(for: language)
            for (key, name) in carriers {
                let value = try XCTUnwrap(table[key], "\(language) is missing \(key)")
                XCTAssertTrue(
                    value.contains(name),
                    "\(language) translated the name \(name) out of \(key): \(value)"
                )
            }
            // "Agentverse" is this app's own coined name for a view of itself.
            // It is a key in its own right, and it is the same word everywhere.
            XCTAssertEqual(table["Agentverse"], "Agentverse", "\(language) renamed the Agentverse")
        }
    }

    /// The two readings of the weekly window are two keys now, not one.
    ///
    /// They were a single `"Week"`: the spend picker's segment, which names a
    /// length of time, and the menu bar's label for the provider's rolling
    /// weekly rate-limit window. English spells both the same and the collision
    /// was invisible; a language that needed two words would have had to pick
    /// one of the two meanings for both places, and nothing would have said so.
    func testTheWeeklyWindowAndTheWeekLongPeriodAreSeparateKeys() throws {
        let english = try compiledTable(for: "en")
        XCTAssertEqual(english["Week"], "Week")
        XCTAssertEqual(english["quotaWindow.weekly.short"], "Week")
        XCTAssertEqual(SpendPeriod.week.title, "Week")
        XCTAssertEqual(RateWindowKind.weekly.shortName, "Week")

        // Each is separately translatable, which is the whole point of the
        // split. Their values may agree in any given language; the keys must
        // not be the same key.
        for language in Self.translatedLanguages {
            let table = try compiledTable(for: language)
            XCTAssertNotNil(table["Week"], "\(language) lost the spend period's Week")
            XCTAssertNotNil(
                table["quotaWindow.weekly.short"],
                "\(language) lost the weekly quota window's own label"
            )
        }
    }

    /// The three sentence fragments that used to land in a `%@` are gone.
    ///
    /// Each was grammatical in English and unusable to a translator who could
    /// not see the sentence it landed in. They are whole phrases now, and the
    /// old fragment keys must not come back — a new caller reintroducing one
    /// would extract to exactly these keys again.
    func testTheSentenceFragmentsAreNoLongerCatalogKeys() {
        for fragment in ["today", "in the last %lld days", "the previous %lld days", "resets", "ends"] {
            // "today" survives as a key in its own right: it is the badge beside
            // a day's title in the chart, a whole label rather than a fragment.
            if fragment == "today" { continue }
            XCTAssertNil(
                catalogValue(for: fragment),
                "\(fragment) is back as a key — it is a sentence fragment and cannot be translated blind"
            )
        }
        // The whole phrases that replaced them.
        for phrase in [
            "resets in %@", "ends in %@", "resets any moment", "ends any moment",
            "resets %@", "ends %@",
            "Nothing recorded on this Mac today.",
            "Nothing recorded on this Mac in the last %lld days.",
            "Level with the previous %lld days",
        ] {
            XCTAssertNotNil(catalogValue(for: phrase), "\(phrase) never reached the catalog")
        }
    }

    // What this file does NOT assert, and why.
    //
    // That `unknownModelLabel` and `otherModelsLabel` still work as the chart's
    // series keys once they are localised. Both are drawn in the legend and used
    // as the key for the rows they stand for, which is worth a test — but the
    // suite is pinned to English, so the localised value still equals the
    // literal *in this process*, and replacing either constant with its own bare
    // literal still leaves every assertion green. A second language in the
    // catalog did not make this writable; only running the suite in a second
    // language would, and that would invalidate every other assertion here.
    //
    // That the translations read well. Nothing in a test can say that. What is
    // asserted is what a machine can check: that every key is present in every
    // shipped language, that no translation changed the format specifiers, and
    // that the names which are not words survived.
    //
    // That SwiftUI actually performs the lookup at render time. There is no
    // view host in this suite to read a rendered `Text` back out of; the
    // extraction above is the part that could realistically be wrong.
}
