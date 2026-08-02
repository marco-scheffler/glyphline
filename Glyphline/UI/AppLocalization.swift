import Foundation

/// The language the app's own words come out in.
///
/// `String(localized:)` resolves against `Bundle.main`, which picks the first of
/// the user's preferred languages the bundle actually carries — so on a Mac set
/// to a language this app has no translation for, the words fall back to the
/// development language and *not* to the system language.
///
/// This exists because a handful of strings are worded by Foundation rather than
/// by the catalog — a relative time such as "11 minutes ago" is the one case —
/// and those formatters follow the system locale by default. Left alone they
/// would print a German "vor 11 Minuten" into a sentence the catalog rendered in
/// English, which reads worse than either language on its own. Asking the bundle
/// keeps the two halves of one sentence in one language.
///
/// Deliberately *not* used for numerals, dates, currencies or anything else with
/// no words in it. Those follow the system locale, which is the reader's region
/// and a separate question from the reader's language.
enum AppLocalization {
    /// The bundle's active localization as a `Locale`, or the development
    /// language when the bundle somehow carries none.
    static var locale: Locale {
        guard let identifier = Bundle.main.preferredLocalizations.first else {
            return Locale(identifier: "en")
        }
        return Locale(identifier: identifier)
    }
}
