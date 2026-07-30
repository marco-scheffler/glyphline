import Foundation

/// Narrow view of the ledger, so the reader can be tested without the full store.
protocol WatermarkStoring: AnyObject {
    func fetchWatermark(sourceKey: String) throws -> SyncWatermark?
    func saveWatermark(_ watermark: SyncWatermark) throws
}

extension LedgerStore: WatermarkStoring {}

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
        }

        var model: String?
        var usage: Usage?
    }

    var timestamp: String
    var message: Message?
}

/// Reads Claude Code transcripts incrementally and aggregates them into daily buckets.
///
/// All stored state is immutable and the parse state lives entirely on the
/// stack, so the class is safe to share; the unchecked escape only exists
/// because `FileManager` and the injected store are not statically `Sendable`.
final class ClaudeCodeLogReader: @unchecked Sendable {
    private let directory: URL
    private let watermarkStore: any WatermarkStoring
    private let fileManager: FileManager
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    init(
        directory: URL,
        watermarkStore: any WatermarkStoring,
        fileManager: FileManager = .default,
        calendar: Calendar = Calendar(identifier: .gregorian),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.watermarkStore = watermarkStore
        self.fileManager = fileManager
        self.now = now
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        self.calendar = utc
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

    /// How far back from `now` the "still open" bucket boundary is pulled.
    ///
    /// A sync captures `now()` once and calls everything before it closed. Without
    /// this margin a sync starting a hair after 00:00 UTC declares the day that just
    /// ended complete, consumes its bytes and advances the watermark to EOF — and a
    /// line for that day flushed milliseconds later is then read by the *next* sync
    /// as a lone fragment, which the replacing ledger upsert writes over that day's
    /// full total. The day is never rescanned, so the loss is silent and permanent.
    /// Manual sync made that a millisecond-wide window; scheduled sync runs
    /// unattended on a fixed interval and will land in it eventually.
    ///
    /// The cost of the margin is re-reading a day that just closed for another
    /// fifteen minutes, which is what the reader already does for the open day all
    /// day long: it is idempotent and emits absolute day totals.
    private static let openBucketGrace: TimeInterval = 15 * 60

    private struct BucketKey: Hashable {
        var dayStart: Date
        var model: String?
    }

    private struct Totals {
        var input: Int64 = 0
        var cacheCreation: Int64 = 0
        var cacheRead: Int64 = 0
        var output: Int64 = 0
    }

    func read(accountID: UUID) throws -> [UsageSnapshot] {
        var totals: [BucketKey: Totals] = [:]
        // Everything from this day onwards belongs to a bucket that can still grow,
        // so those bytes stay unconsumed and are re-read every sync. Taken from
        // `now` minus the grace period, so a sync that crosses midnight does not
        // close the day it is still straddling. See `openBucketGrace`.
        let openDayStart = calendar.startOfDay(for: now().addingTimeInterval(-Self.openBucketGrace))
        // Built once per sync, not once per line: `ISO8601DateFormatter` is
        // expensive to construct and `read` parses millions of lines on a cold start.
        let dates = TimestampParser()

        for file in transcriptURLs() {
            try consume(
                file,
                accountID: accountID,
                openDayStart: openDayStart,
                dates: dates,
                into: &totals
            )
        }

        return totals.map { key, value in
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: key.dayStart) ?? key.dayStart

            return UsageSnapshot(
                id: SnapshotIdentity.make(
                    accountID: accountID,
                    providerID: .claude,
                    bucketStart: key.dayStart,
                    bucketEnd: dayEnd,
                    discriminator: key.model ?? "usage"
                ),
                accountID: accountID,
                providerID: .claude,
                bucketStart: key.dayStart,
                bucketEnd: dayEnd,
                model: key.model,
                inputTokens: value.input,
                cacheCreationTokens: value.cacheCreation,
                cacheReadTokens: value.cacheRead,
                outputTokens: value.output,
                requests: nil,
                quality: .partial
            )
        }
        .sorted { $0.bucketStart < $1.bucketStart }
    }

    private func transcriptURLs() -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.path < $1.path }
    }

    private func consume(
        _ file: URL,
        accountID: UUID,
        openDayStart: Date,
        dates: TimestampParser,
        into totals: inout [BucketKey: Totals]
    ) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)

        let stored = try watermarkStore.fetchWatermark(sourceKey: file.path)
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
        // Bytes, relative to `offset`, that belong to buckets no longer able to
        // grow. The watermark never moves past this point, so a bucket is never
        // split across two reads and every bucket is emitted in full.
        var consumable = 0
        var reachedOpenBucket = false
        var lineStart = complete.startIndex

        while lineStart <= lastNewline,
              let newline = complete[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = complete[lineStart ..< newline]
            let lineEnd = complete.distance(from: complete.startIndex, to: newline) + 1
            lineStart = complete.index(after: newline)

            if let record = try? decoder.decode(ClaudeCodeLogRecord.self, from: Data(line)),
               let usage = record.message?.usage,
               let timestamp = dates.date(from: record.timestamp) {
                let dayStart = calendar.startOfDay(for: timestamp)
                if dayStart >= openDayStart {
                    reachedOpenBucket = true
                }

                let key = BucketKey(dayStart: dayStart, model: record.message?.model)
                var bucket = totals[key] ?? Totals()
                bucket.input += usage.inputTokens ?? 0
                bucket.cacheCreation += usage.cacheCreationInputTokens ?? 0
                bucket.cacheRead += usage.cacheReadInputTokens ?? 0
                bucket.output += usage.outputTokens ?? 0
                totals[key] = bucket
            }

            if !reachedOpenBucket {
                consumable = lineEnd
            }
        }

        try watermarkStore.saveWatermark(
            SyncWatermark(
                sourceKey: file.path,
                accountID: accountID,
                fileSize: size,
                fileMTime: modified,
                byteOffset: offset + Int64(consumable),
                updatedAt: Date()
            )
        )
    }
}

/// Parses transcript timestamps, holding its formatters for the length of one sync.
///
/// `ISO8601DateFormatter` is not `Sendable`, so a static instance would need an
/// unsafe opt-out; constructing one per line would dominate the parse. A short-lived
/// value owned by a single call needs neither. Transcript timestamps carry fractional
/// seconds, which the formatter rejects unless `.withFractionalSeconds` is set —
/// hence the second, plain formatter as a fallback.
private struct TimestampParser {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}
