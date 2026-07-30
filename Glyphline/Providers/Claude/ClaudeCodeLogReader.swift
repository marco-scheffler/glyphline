import Foundation

/// Narrow view of the ledger, so the reader can be tested without the full store.
///
/// Account-free on purpose: the transcripts under `~/.claude/projects` carry no
/// marker of which subscription was active, so the scan they feed is
/// machine-wide and has no account to key its resume point by.
protocol LocalScanWatermarkStoring: AnyObject {
    func fetchLocalScanWatermark(sourceKey: String) throws -> LocalScanWatermark?
    func saveLocalScanWatermark(_ watermark: LocalScanWatermark) throws
}

extension LedgerStore: LocalScanWatermarkStoring {}

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

    init(
        directory: URL,
        watermarkStore: any LocalScanWatermarkStoring,
        fileManager: FileManager = .default,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        self.directory = directory
        self.watermarkStore = watermarkStore
        self.fileManager = fileManager
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

    /// Reads everything not yet consumed and returns it as per-day, per-model
    /// *deltas*.
    ///
    /// Each returned row carries only the tokens read by this call, because
    /// `upsertLocalTokenUsage` adds a row to what is already stored rather than
    /// replacing it. Every complete line is therefore consumed and the watermark
    /// advances past it: re-reading a day would add its tokens a second time.
    func read() throws -> [LocalTokenUsage] {
        var totals: [BucketKey: Totals] = [:]
        // Built once per sync, not once per line: `ISO8601DateFormatter` is
        // expensive to construct and `read` parses millions of lines on a cold start.
        let dates = TimestampParser()

        for file in transcriptURLs() {
            try consume(file, dates: dates, into: &totals)
        }

        return totals.map { key, value in
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
        dates: TimestampParser,
        into totals: inout [BucketKey: Totals]
    ) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)

        let stored = try watermarkStore.fetchLocalScanWatermark(sourceKey: file.path)
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
               let timestamp = dates.date(from: record.timestamp) {
                let dayStart = calendar.startOfDay(for: timestamp)
                let key = BucketKey(dayStart: dayStart, model: record.message?.model)
                var bucket = totals[key] ?? Totals()
                bucket.input += usage.inputTokens ?? 0
                bucket.cacheCreation += usage.cacheCreationInputTokens ?? 0
                bucket.cacheRead += usage.cacheReadInputTokens ?? 0
                bucket.output += usage.outputTokens ?? 0
                totals[key] = bucket
            }

            consumable = lineEnd
        }

        try watermarkStore.saveLocalScanWatermark(
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
