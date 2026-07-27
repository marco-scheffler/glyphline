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

    init(
        directory: URL,
        watermarkStore: any WatermarkStoring,
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

    /// Slack allowed on the stored modification date before a file counts as rewritten.
    private static let mTimeTolerance: TimeInterval = 1

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

        for file in transcriptURLs() {
            try consume(file, accountID: accountID, into: &totals)
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
        into totals: inout [BucketKey: Totals]
    ) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)

        let stored = try watermarkStore.fetchWatermark(sourceKey: file.path)
        // A file that shrank or moved backwards in time was rewritten; start over.
        // The ledger stores dates at millisecond precision and rounds, so an
        // unchanged file can come back a hair ahead of its own mtime; only a
        // move of more than a second counts as backwards.
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
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                  let record = try? decoder.decode(ClaudeCodeLogRecord.self, from: Data(line)),
                  let usage = record.message?.usage,
                  let timestamp = Self.date(from: record.timestamp) else {
                continue
            }

            let key = BucketKey(
                dayStart: calendar.startOfDay(for: timestamp),
                model: record.message?.model
            )
            var bucket = totals[key] ?? Totals()
            bucket.input += usage.inputTokens ?? 0
            bucket.cacheCreation += usage.cacheCreationInputTokens ?? 0
            bucket.cacheRead += usage.cacheReadInputTokens ?? 0
            bucket.output += usage.outputTokens ?? 0
            totals[key] = bucket
        }

        try watermarkStore.saveWatermark(
            SyncWatermark(
                sourceKey: file.path,
                accountID: accountID,
                fileSize: size,
                fileMTime: modified,
                byteOffset: offset + Int64(complete.count),
                updatedAt: Date()
            )
        )
    }

    /// Fresh formatters per call: `ISO8601DateFormatter` is not `Sendable`, so a
    /// shared static one would need an unsafe opt-out for a negligible saving.
    /// Transcript timestamps carry fractional seconds, which the formatter
    /// rejects unless `.withFractionalSeconds` is set — hence the second pass.
    private static func makeFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    static func date(from string: String) -> Date? {
        makeFormatter(fractionalSeconds: true).date(from: string)
            ?? makeFormatter(fractionalSeconds: false).date(from: string)
    }
}
