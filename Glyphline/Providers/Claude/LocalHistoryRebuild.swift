import Foundation

/// One full re-read of every surviving transcript, carrying both answers the
/// per-day decision needs.
///
/// `scan` is the deduplicated truth — the same shape a normal scan produces, so
/// it lands through the same one-transaction path. The naive totals are never
/// written anywhere; they exist only to be compared against what is recorded.
struct LocalHistoryRebuildScan: Equatable, Sendable {
    var scan: LocalScanResult
    /// Total tokens per day counting **every** occurrence, exactly as the
    /// scanner did before it deduplicated by `message.id`. Keyed on the same
    /// day grid `scan` is — the reader's calendar — so the two can be compared
    /// bucket for bucket.
    var naiveDailyTotals: [Date: Int64] = [:]
    /// The same figure per session id: every occurrence carrying that
    /// `sessionId`, counted the way the old scanner counted it. Records without
    /// a `sessionId` belong to no session and appear here in no entry.
    var naiveSessionTotals: [String: Int64] = [:]
}

/// The one-time corrections of a local history that was recorded wrongly, and
/// the single rule that decides whether a given day may be corrected at all.
///
/// Two of them have run. The first: until the scanner deduplicated by
/// `message.id` it counted the same assistant message once per transcript that
/// contained it, and Claude Code copies a session's history into a new file on
/// resume or fork — 2.19x over-count on the reference machine. The second: the
/// buckets were UTC days while the screen called them "today", so every day held
/// the wrong hours. Fixing the scanner only ever fixes new scans; the history
/// already on disk needs a pass of its own, and both passes ask the same
/// question of each day before they touch it.
enum LocalHistoryRebuild {
    /// The share of a recorded figure the surviving transcripts must still
    /// account for before it may be replaced.
    ///
    /// One number for both halves of the rebuild, deliberately. The rule is the
    /// same whether the bucket is a day or a session id — only the grouping
    /// differs — and a second constant would be a second answer to the same
    /// question, free to drift away from the one that was measured.
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
    ///
    /// **What the second pass does to this ratio.** Re-bucketing to local days
    /// runs the same rule a second time, but its denominator is what the first
    /// pass left behind — deduplicated for every day it touched — while the
    /// numerator is still the naive sum. Coverage on an intact day therefore
    /// reads about 2.0 rather than about 1.0, and the rule degenerates from "do
    /// the surviving files reproduce this arithmetic" to the weaker but still
    /// sufficient "are the files still there". Measured across the reference
    /// machine's 43 recorded dates at that pass, sorted: 0.000, 0.000, 0.000,
    /// 0.044, 0.239, 0.430, 0.841, then 0.993 and upward. The threshold stays
    /// where it was because nothing lies between 0.841 and 0.993 — and lowering
    /// it would only weaken the guard on 2026-07-04, the one day in that gap,
    /// whose files really are partly gone.
    ///
    /// The two days the first pass had to keep — 2026-07-30 and 2026-07-31, at
    /// 0.92 and 0.96 against a naive denominator, still carrying the 2.2x
    /// over-count — measure 1.003 and 0.993 here and are corrected by the second
    /// pass without the constant moving at all.
    static let replacementCoverageThreshold = 0.97

    /// Whether a recorded figure may be replaced by the deduplicated one — for a
    /// day, and unchanged for a session.
    ///
    /// Pure arithmetic over two numbers, so the safety property is testable
    /// without a database or a transcript.
    ///
    /// A bucket with nothing recorded is not a correction — it is new data, and
    /// no coverage ratio against zero is invented for it; it reports `false` here
    /// and is inserted rather than replaced.
    static func shouldReplace(recorded: Int64, naiveFromSurvivingFiles naive: Int64) -> Bool {
        guard recorded > 0 else { return false }
        return Double(naive) / Double(recorded) >= replacementCoverageThreshold
    }
}
