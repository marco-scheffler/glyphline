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
        #"Delete "\#(displayName)"?"#
    }

    static func body(summary: AccountDeletionSummary, source: AccountSource) -> String {
        var paragraphs: [String] = []

        if summary.rateWindowSampleCount > 0 {
            let noun = summary.rateWindowSampleCount == 1 ? "sample" : "samples"
            var sentence = "\(summary.rateWindowSampleCount.formatted(.number)) rate window \(noun) "
            if let earliest = summary.earliestRateWindowObservedAt {
                // `.numeric`, not `.abbreviated`: an abbreviated date spells the
                // month, and a spelled month follows the *system* language. On a
                // German Mac that drops "Okt." into this English sentence, in the
                // app's only irreversible dialog. Forcing English here would fix
                // the word and break the order — "10/4/2026" for a reader who
                // reads day first. `.numeric` renders "04.10.2026": no word to
                // translate, numerals still local.
                sentence += "recorded since \(earliest.formatted(date: .numeric, time: .omitted)). "
            } else {
                sentence += "recorded. "
            }
            sentence += "This cannot be recovered — claude.ai reports only the current figure, "
            sentence += "so this history exists nowhere else."
            paragraphs.append(sentence)
        }

        if source == .claudeWebSession {
            paragraphs.append("Its claude.ai sign-in will be removed from this Mac.")
        }

        if paragraphs.isEmpty {
            paragraphs.append("This account has no recorded history.")
        }

        return paragraphs.joined(separator: "\n\n")
    }
}
