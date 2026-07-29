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
                sentence += "recorded since \(earliest.formatted(date: .abbreviated, time: .omitted)). "
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
            counts.append("\(summary.costSnapshotCount.formatted(.number)) cost snapshots")
        }
        if summary.usageSnapshotCount > 0 {
            counts.append("\(summary.usageSnapshotCount.formatted(.number)) usage snapshots")
        }

        if !counts.isEmpty {
            // "These" reads correctly in all three shapes, because every shape
            // ends in a plural noun phrase — "12 cost snapshots", not "12 cost".
            paragraphs.append(
                "\(counts.joined(separator: " and ")). These can be rebuilt by adding the "
                + "account again and syncing, as far back as the source still reaches."
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
