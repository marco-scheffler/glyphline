import Foundation

/// The sentences shown before an account is deleted.
///
/// Its whole job is one distinction. Cost and token history is derived from a
/// source that still exists — the transcripts, or the provider's API — so
/// re-adding the account rebuilds it. Rate window samples are observations of a
/// number nobody keeps: claude.ai reports what the figure is now and has no
/// memory of what it was, so once these rows are gone the record is gone.
///
/// A user deciding to delete deserves to know which of those two they are
/// looking at, and whether it is two samples or half a year.
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

        // A count of zero is not history, and naming it as if it were is the
        // same noise the zero-samples rule above exists to avoid. Only the
        // counts that actually have rows are named.
        var counts: [String] = []
        if summary.costSnapshotCount > 0 {
            let noun = summary.costSnapshotCount == 1 ? "cost snapshot" : "cost snapshots"
            counts.append("\(summary.costSnapshotCount.formatted(.number)) \(noun)")
        }
        if summary.usageSnapshotCount > 0 {
            let noun = summary.usageSnapshotCount == 1 ? "usage snapshot" : "usage snapshots"
            counts.append("\(summary.usageSnapshotCount.formatted(.number)) \(noun)")
        }

        if !counts.isEmpty {
            // The pronoun follows the phrase it refers back to. One shape is
            // singular — a single count of exactly one — and "1 cost snapshot.
            // These can be rebuilt" is the same broken agreement the nouns above
            // used to produce, in the app's only irreversible dialog.
            let isPlural = counts.count > 1
                || summary.costSnapshotCount > 1
                || summary.usageSnapshotCount > 1
            paragraphs.append(
                "\(counts.joined(separator: " and ")). \(isPlural ? "These" : "This") can be "
                + "rebuilt by adding the account again and syncing, as far back as the source "
                + "still reaches."
            )
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
