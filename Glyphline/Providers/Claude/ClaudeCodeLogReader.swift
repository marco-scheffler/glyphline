import Foundation

/// Narrow view of the ledger, so the reader can be tested without the full store.
///
/// Fetch only. The reader emits deltas, so the tokens it read and the watermarks
/// that consume them have to be persisted together or not at all — a save here
/// would let the reader advance a resume point on its own and lose the tokens
/// that went with it. Writing is the caller's job, through
/// `LedgerStore.applyLocalScan(_:)`.
///
/// Account-free on purpose: the transcripts under `~/.claude/projects` carry no
/// marker of which subscription was active, so the scan they feed is
/// machine-wide and has no account to key its resume point by.
protocol LocalScanWatermarkStoring: AnyObject {
    func fetchLocalScanWatermark(sourceKey: String) throws -> LocalScanWatermark?
    /// Ids of the assistant messages already counted, so a copy of one in a
    /// forked transcript is not counted a second time.
    func fetchSeenMessageIDs() throws -> Set<String>
}

extension LedgerStore: LocalScanWatermarkStoring {}

/// One scan's tokens together with the resume points that consume them.
///
/// The two halves are inseparable: `usage` holds only the tokens read since the
/// last resume point, and `watermarks` is what makes those bytes unreadable
/// again. Persist both in one transaction — `LedgerStore.applyLocalScan` — or
/// neither; anything else loses tokens permanently on the next interruption.
struct LocalScanResult: Equatable, Sendable {
    var usage: [LocalTokenUsage]
    /// The same tokens, gathered by session instead of by day. Derived in the
    /// same pass from the same records, so the two can never disagree.
    var sessionUsage: [LocalSessionTokenUsage] = []
    var watermarks: [LocalScanWatermark]
    /// The ids of the messages whose tokens are in `usage`. Inseparable from it
    /// for the same reason the watermarks are: recorded without their tokens
    /// they suppress a real record forever, and the tokens recorded without them
    /// are counted again by the next fork.
    var seenMessages: [LocalSeenMessage] = []
}

/// One assistant record in a Claude Code transcript. Records that are not
/// assistant turns simply fail to decode and are skipped.
private struct ClaudeCodeLogRecord: Decodable {
    struct Message: Decodable {
        struct Usage: Decodable {
            var inputTokens: Int64?
            var cacheCreationInputTokens: Int64?
            var cacheReadInputTokens: Int64?
            var outputTokens: Int64?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case outputTokens = "output_tokens"
            }

            var totalTokens: Int64 {
                (inputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
                    + (cacheReadInputTokens ?? 0) + (outputTokens ?? 0)
            }
        }

        /// The API's message id. Stable across every copy of the message, which
        /// is what makes deduplication possible at all.
        var id: String?
        var model: String?
        var usage: Usage?
    }

    var sessionId: String?
    var timestamp: String
    var message: Message?
}

/// Reads Claude Code transcripts incrementally and aggregates them into daily buckets.
///
/// The result is machine-wide and account-free. The transcripts carry no marker of
/// which Claude subscription was active — `/login` writes into the same directory —
/// so the totals are the sum across every subscription and cannot be split.
///
/// All stored state is immutable and the parse state lives entirely on the
/// stack, so the class is safe to share; the unchecked escape only exists
/// because `FileManager` and the injected store are not statically `Sendable`.
final class ClaudeCodeLogReader: @unchecked Sendable {
    private let directory: URL
    private let watermarkStore: any LocalScanWatermarkStoring
    private let fileManager: FileManager
    private let calendar: Calendar

    /// - Parameter calendar: where one day ends and the next begins. Defaults to
    ///   the user's, which is the only grid a figure labelled "today" can be
    ///   read on; a test injects a fixed one so its expected buckets do not
    ///   depend on the machine that runs it.
    init(
        directory: URL,
        watermarkStore: any LocalScanWatermarkStoring,
        fileManager: FileManager = .default,
        calendar: Calendar = LocalUsageDay.calendar
    ) {
        self.directory = directory
        self.watermarkStore = watermarkStore
        self.fileManager = fileManager
        self.calendar = calendar
    }

    /// Tolerance on the stored modification date before a file counts as rewritten.
    ///
    /// Sized to the ledger's own rounding, nothing more: dates are stored at
    /// millisecond precision and rounded, so an untouched file can come back up to
    /// half a millisecond behind its own mtime. Two milliseconds absorbs that with
    /// room to spare. Anything larger is a blind spot in the one check that decides
    /// whether a stored byte offset can still be trusted — a file rewritten in
    /// place within the tolerance would be resumed from a stale offset.
    private static let mTimeTolerance: TimeInterval = 0.002

    /// Names Claude Code writes in the `model` field for assistant turns it
    /// produced itself instead of receiving from the API — an error notice, an
    /// interrupt. They carry a usage block of zeros, so recording them adds
    /// nothing but a row named after something that is not a model and can never
    /// be priced.
    private static let placeholderModelNames: Set<String> = ["<synthetic>"]

    private static func isPlaceholderModel(_ model: String?) -> Bool {
        guard let model else { return false }
        return placeholderModelNames.contains(model)
    }

    /// Whether this record's tokens have already been counted, remembering it if
    /// they have not.
    ///
    /// A record with no `message.id` cannot be deduplicated, so it is counted —
    /// exactly as before this guard existed, and again if it recurs. That is a
    /// deliberate limit: silently dropping usage that cannot be identified would
    /// trade an over-count for an under-count, which is the worse of the two
    /// because nothing would ever reveal it.
    private static func isAlreadyCounted(
        _ messageID: String?,
        seen: inout Set<String>,
        newlySeen: inout [LocalSeenMessage]
    ) -> Bool {
        guard let messageID, !messageID.isEmpty else { return false }
        guard seen.insert(messageID).inserted else { return true }
        newlySeen.append(LocalSeenMessage(messageID: messageID, seenAt: Date()))
        return false
    }

    private struct BucketKey: Hashable {
        var dayStart: Date
        var model: String?
    }

    private struct SessionKey: Hashable {
        var sessionID: String
        var model: String?
    }

    private struct Totals {
        var input: Int64 = 0
        var cacheCreation: Int64 = 0
        var cacheRead: Int64 = 0
        var output: Int64 = 0
    }

    /// Reads everything not yet consumed and returns it as per-day, per-model
    /// *deltas*, paired with the resume points that consume them.
    ///
    /// Each returned row carries only the tokens read by this call, because
    /// `upsertLocalTokenUsage` adds a row to what is already stored rather than
    /// replacing it. Nothing is persisted here: the returned watermarks must be
    /// written in the same transaction as the rows, or the tokens between the
    /// old and the new resume point are lost for good.
    func read() throws -> LocalScanResult {
        try scan(rebuilding: false).scan
    }

    /// Re-reads **every** surviving transcript from byte zero, ignoring the stored
    /// resume points and the stored seen ids, and returns the deduplicated result
    /// alongside the naive per-day totals the old scanner would have produced.
    ///
    /// Both aggregates come out of the one pass on purpose: the coverage ratio
    /// that decides whether a day may be replaced compares them, and two figures
    /// read from 1.86 GB of transcripts at different times could disagree.
    ///
    /// Nothing is persisted here. The result belongs to
    /// `LedgerStore.applyLocalHistoryRebuild(_:)`, in one transaction.
    func readForRebuild() throws -> LocalHistoryRebuildScan {
        try scan(rebuilding: true)
    }

    private func scan(rebuilding: Bool) throws -> LocalHistoryRebuildScan {
        var totals: [BucketKey: Totals] = [:]
        var sessionTotals: [SessionKey: Totals] = [:]
        var watermarks: [LocalScanWatermark] = []
        var naiveDailyTotals: [Date: Int64] = [:]
        var naiveSessionTotals: [String: Int64] = [:]
        // Built once per sync, not once per line: `ISO8601DateFormatter` is
        // expensive to construct and `read` parses millions of lines on a cold start.
        let dates = TranscriptTimestampParser()

        // Read once per scan, not once per line. The set carries the ids from
        // every previous scan — which is the whole point, since a fork's parent
        // was consumed in an earlier pass — and grows as this scan counts more,
        // so a message copied into two files within one scan is also caught.
        //
        // A rebuild starts from an empty set instead: it re-reads every file
        // whole, so every id it meets is one it is counting for the first time
        // in this pass, and the stored set would suppress all of them.
        var seen = rebuilding ? [] : try watermarkStore.fetchSeenMessageIDs()
        var newlySeen: [LocalSeenMessage] = []

        for file in transcriptURLs() {
            try consume(file, dates: dates, rebuilding: rebuilding, into: &totals,
                        sessions: &sessionTotals, naiveDaily: &naiveDailyTotals,
                        naiveSessions: &naiveSessionTotals,
                        watermarks: &watermarks, seen: &seen, newlySeen: &newlySeen)
        }

        let usage = totals.map { key, value in
            LocalTokenUsage(
                bucketStart: key.dayStart,
                model: key.model,
                inputTokens: value.input,
                cacheCreationTokens: value.cacheCreation,
                cacheReadTokens: value.cacheRead,
                outputTokens: value.output
            )
        }
        .sorted { $0.bucketStart < $1.bucketStart }

        let sessionUsage = sessionTotals.map { key, value in
            LocalSessionTokenUsage(
                sessionID: key.sessionID,
                model: key.model,
                inputTokens: value.input,
                cacheCreationTokens: value.cacheCreation,
                cacheReadTokens: value.cacheRead,
                outputTokens: value.output
            )
        }
        .sorted { ($0.sessionID, $0.modelKey) < ($1.sessionID, $1.modelKey) }

        return LocalHistoryRebuildScan(
            scan: LocalScanResult(
                usage: usage,
                sessionUsage: sessionUsage,
                watermarks: watermarks,
                seenMessages: newlySeen
            ),
            naiveDailyTotals: naiveDailyTotals,
            naiveSessionTotals: naiveSessionTotals
        )
    }

    private func transcriptURLs() -> [URL] {
        ClaudeTranscriptDirectory.transcriptURLs(
            in: directory,
            fileManager: fileManager,
            prefetching: [.fileSizeKey, .contentModificationDateKey]
        )
    }

    private func consume(
        _ file: URL,
        dates: TranscriptTimestampParser,
        rebuilding: Bool,
        into totals: inout [BucketKey: Totals],
        sessions: inout [SessionKey: Totals],
        naiveDaily: inout [Date: Int64],
        naiveSessions: inout [String: Int64],
        watermarks: inout [LocalScanWatermark],
        seen: inout Set<String>,
        newlySeen: inout [LocalSeenMessage]
    ) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)

        // A rebuild reads from byte zero regardless of where the last scan
        // stopped; that is what makes its figures whole rather than a delta.
        let stored = rebuilding ? nil : try watermarkStore.fetchLocalScanWatermark(sourceKey: file.path)
        // A file that shrank or moved backwards in time was rewritten; start over.
        // The ledger stores dates at millisecond precision and rounds, so an
        // unchanged file can come back a hair ahead of its own mtime; the
        // tolerance is sized just above that sub-millisecond error, see
        // `mTimeTolerance`.
        let rewritten = stored.map { watermark in
            size < watermark.fileSize
                || modified.timeIntervalSince(watermark.fileMTime) < -Self.mTimeTolerance
        } ?? false
        var offset = rewritten ? 0 : (stored?.byteOffset ?? 0)

        if offset > size {
            offset = 0
        }

        guard offset < size else {
            return
        }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.readToEnd() ?? Data()

        // Only consume through the last complete line; a partially written
        // trailing line is left for the next pass.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return
        }
        let complete = data[data.startIndex ... lastNewline]

        let decoder = JSONDecoder()
        // Bytes, relative to `offset`, that this pass has read in full. Every
        // complete line counts: the emitted rows are deltas the store adds, so a
        // bucket may be split across reads, but a line must never be read twice.
        var consumable = 0
        var lineStart = complete.startIndex

        while lineStart <= lastNewline,
              let newline = complete[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = complete[lineStart ..< newline]
            let lineEnd = complete.distance(from: complete.startIndex, to: newline) + 1
            lineStart = complete.index(after: newline)

            if let record = try? decoder.decode(ClaudeCodeLogRecord.self, from: Data(line)),
               let usage = record.message?.usage,
               let timestamp = dates.date(from: record.timestamp),
               !Self.isPlaceholderModel(record.message?.model) {
                let dayStart = calendar.startOfDay(for: timestamp)

                // Counted before the deduplication guard, and therefore counting
                // every copy — this is deliberately the arithmetic of the bug, so
                // a rebuild can ask whether the surviving files still reproduce
                // what the buggy scanner recorded for this day.
                if rebuilding {
                    naiveDaily[dayStart, default: 0] += usage.totalTokens
                    if let sessionID = record.sessionId {
                        naiveSessions[sessionID, default: 0] += usage.totalTokens
                    }
                }

                guard !Self.isAlreadyCounted(record.message?.id, seen: &seen, newlySeen: &newlySeen) else {
                    consumable = lineEnd
                    continue
                }

                let key = BucketKey(dayStart: dayStart, model: record.message?.model)
                var bucket = totals[key] ?? Totals()
                bucket.input += usage.inputTokens ?? 0
                bucket.cacheCreation += usage.cacheCreationInputTokens ?? 0
                bucket.cacheRead += usage.cacheReadInputTokens ?? 0
                bucket.output += usage.outputTokens ?? 0
                totals[key] = bucket

                // Same record, second question. Derived here rather than in a
                // pass of its own: these transcripts run to 1.86 GB, and two
                // figures read from the same lines at different times could
                // disagree — which in an app about token counts is the worst
                // kind of defect, plausible and wrong.
                //
                // Gathered by a rebuild too, and for the same reason the day
                // totals are: the per-day coverage rule transfers to sessions
                // unchanged — group by `sessionId` instead of by day and the
                // arithmetic is identical — so `applyLocalSessionTokenRebuild`
                // has the evidence it needs to correct these as well.
                //
                // A record with no `sessionId` belongs to no session and simply
                // does not participate, here or in the naive totals above.
                if let sessionID = record.sessionId {
                    let sessionKey = SessionKey(sessionID: sessionID, model: record.message?.model)
                    var session = sessions[sessionKey] ?? Totals()
                    session.input += usage.inputTokens ?? 0
                    session.cacheCreation += usage.cacheCreationInputTokens ?? 0
                    session.cacheRead += usage.cacheReadInputTokens ?? 0
                    session.output += usage.outputTokens ?? 0
                    sessions[sessionKey] = session
                }
            }

            consumable = lineEnd
        }

        watermarks.append(
            LocalScanWatermark(
                sourceKey: file.path,
                fileSize: size,
                fileMTime: modified,
                byteOffset: offset + Int64(consumable),
                updatedAt: Date()
            )
        )
    }
}
