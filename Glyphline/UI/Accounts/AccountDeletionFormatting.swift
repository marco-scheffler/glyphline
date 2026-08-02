import Foundation

/// The sentences shown before an account is deleted.
///
/// Its whole job is one warning. Rate window samples are observations of a
/// number nobody keeps: claude.ai reports what the figure is now and has no
/// memory of what it was, so once these rows are gone the record is gone.
///
/// A user deciding to delete deserves to know that, and whether it is two
/// samples or half a year.
enum AccountDeletionFormatting {
    static func title(displayName: String) -> String {
        String(
            localized: #"Delete "\#(displayName)"?"#,
            comment: "Delete confirmation title. The placeholder is the account's display name; the quotation marks around it are part of the sentence."
        )
    }

    static func body(summary: AccountDeletionSummary, source: AccountSource) -> String {
        var paragraphs: [String] = []

        if summary.rateWindowSampleCount > 0 {
            // Whole sentences rather than the fragments this used to concatenate.
            // Four keys for two counts times two date cases is more keys, and it
            // is the difference between a translator seeing a sentence and a
            // translator seeing the word "recorded." on its own.
            let count = summary.rateWindowSampleCount.formatted(.number)
            let opening: String
            // `.numeric`, not `.abbreviated`: an abbreviated date spells the
            // month, and a spelled month follows the *system* language. On a
            // German Mac that drops "Okt." into a sentence the catalog may have
            // rendered in another language. `.numeric` renders "04.10.2026": no
            // word in it, numerals still the reader's own.
            if let earliest = summary.earliestRateWindowObservedAt {
                let since = earliest.formatted(date: .numeric, time: .omitted)
                opening = summary.rateWindowSampleCount == 1
                    ? String(
                        localized: "\(count) rate window sample recorded since \(since).",
                        comment: "Delete dialog, singular. Placeholders: the sample count (always 1) and a date."
                    )
                    : String(
                        localized: "\(count) rate window samples recorded since \(since).",
                        comment: "Delete dialog, plural. Placeholders: the sample count (2 or more) and a date."
                    )
            } else {
                opening = summary.rateWindowSampleCount == 1
                    ? String(
                        localized: "\(count) rate window sample recorded.",
                        comment: "Delete dialog, singular, with no earliest date on file. The placeholder is the sample count (always 1)."
                    )
                    : String(
                        localized: "\(count) rate window samples recorded.",
                        comment: "Delete dialog, plural, with no earliest date on file. The placeholder is the sample count (2 or more)."
                    )
            }

            let warning = String(
                localized: "This cannot be recovered — claude.ai reports only the current figure, so this history exists nowhere else.",
                comment: "Delete dialog: why the rate window history cannot be rebuilt."
            )
            paragraphs.append("\(opening) \(warning)")
        }

        if source == .claudeWebSession {
            paragraphs.append(String(
                localized: "Its claude.ai sign-in will be removed from this Mac.",
                comment: "Delete dialog: the stored claude.ai web session goes with the account."
            ))
        }

        if paragraphs.isEmpty {
            paragraphs.append(String(
                localized: "This account has no recorded history.",
                comment: "Delete dialog for an account with nothing stored against it."
            ))
        }

        return paragraphs.joined(separator: "\n\n")
    }
}
