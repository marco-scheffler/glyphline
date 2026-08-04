import Foundation

/// One full re-read of every surviving transcript, carrying both answers the
/// per-day decision needs.
///
/// `scan` is the deduplicated truth — the same shape a normal scan produces, so
/// it lands through the same one-transaction path. `naiveDailyTotals` is never
/// written anywhere; it exists only to be compared against what is recorded.
struct LocalHistoryRebuildScan: Equatable, Sendable {
    var scan: LocalScanResult
    /// Total tokens per UTC day counting **every** occurrence, exactly as the
    /// scanner did before it deduplicated by `message.id`.
    var naiveDailyTotals: [Date: Int64] = [:]
}

/// The one-time correction of a local history recorded by the counting bug.
///
/// Until the scanner deduplicated by `message.id` it counted the same assistant
/// message once per transcript that contained it, and Claude Code copies a
/// session's history into a new file on resume or fork — 2.19x over-count on the
/// reference machine. Fixing the scanner only fixed new scans.
enum LocalHistoryRebuild {
    /// The share of a day's recorded tokens the surviving transcripts must still
    /// account for before that day may be replaced.
    ///
    /// Sum the day's usage from surviving transcripts *naively* — counting every
    /// occurrence, exactly as the old buggy scanner did. If that reproduces what
    /// is recorded, the recorded figure came from files that still exist, so the
    /// deduplicated figure for that day is trustworthy and replaces it. If it
    /// falls short, files are missing; leave the recorded figure alone.
    ///
    /// A blanket rescan is not an option: Claude Code moved subagent sessions out
    /// of `<session>/subagents/agent-*.jsonl` into inline `isSidechain` records,
    /// and sessions run in since-removed git worktrees leave nothing behind
    /// either. On the reference machine 372 files had vanished and a naive
    /// rebuild would have destroyed 11.5 Gtok of real recorded usage, two days of
    /// it — 4 Gtok — down to zero.
    ///
    /// Coverage above 1.0 is normal and must also replace: it means the recorded
    /// value was a partial day the scanner had not finished (2026-08-03 measured
    /// 119.7%).
    ///
    /// Validated against the reference machine's data: 33 days replaced, 8 kept,
    /// and 32 of the 33 replaced days afterwards matched an independent
    /// deduplicated count exactly; the 33rd was the current day, still accruing.
    static let replacementCoverageThreshold = 0.97

    /// Whether a day's recorded figure may be replaced by the deduplicated one.
    ///
    /// Pure arithmetic over two numbers, so the safety property is testable
    /// without a database or a transcript.
    ///
    /// A day with nothing recorded is not a correction — it is new data, and no
    /// coverage ratio against zero is invented for it; it reports `false` here
    /// and is inserted rather than replaced.
    static func shouldReplace(recorded: Int64, naiveFromSurvivingFiles naive: Int64) -> Bool {
        guard recorded > 0 else { return false }
        return Double(naive) / Double(recorded) >= replacementCoverageThreshold
    }
}
