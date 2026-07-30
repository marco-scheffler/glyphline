import GRDB
import XCTest
@testable import Glyphline

final class ClaudeCodeLogReaderTests: XCTestCase {
    private var directory: URL!
    private var ledger: LedgerStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glyphline-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("project-a", isDirectory: true),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        ledger = LedgerStore(dbQueue: dbQueue)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func line(model: String, input: Int, cacheWrite: Int, cacheRead: Int, output: Int, timestamp: String) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","message":{"model":"\(model)","usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead),"output_tokens":\(output)}}}
        """
    }

    private func write(_ contents: String, to name: String) throws {
        let url = directory.appendingPathComponent("project-a/\(name)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ contents: String, to name: String) throws {
        let url = directory.appendingPathComponent("project-a/\(name)")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
        try handle.close()
    }

    /// Persists a scan the way production must: rows and watermarks in one
    /// transaction. Returns the rows, so a test can assert on the deltas.
    @discardableResult
    private func apply(_ result: LocalScanResult) throws -> [LocalTokenUsage] {
        try ledger.applyLocalScan(usage: result.usage, watermarks: result.watermarks)
        return result.usage
    }

    func testAggregatesUsageByDayAndModel() throws {
        try write(
            [
                line(model: "claude-opus-4-8", input: 10, cacheWrite: 20, cacheRead: 30, output: 40, timestamp: "2026-07-01T09:00:00.000Z"),
                line(model: "claude-opus-4-8", input: 1, cacheWrite: 2, cacheRead: 3, output: 4, timestamp: "2026-07-01T18:00:00.000Z"),
                line(model: "claude-haiku-4-5", input: 5, cacheWrite: 0, cacheRead: 0, output: 5, timestamp: "2026-07-01T18:30:00.000Z"),
            ].joined(separator: "\n") + "\n",
            to: "session.jsonl"
        )

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
        let rows = try apply(reader.read())

        XCTAssertEqual(rows.count, 2)

        let opus = try XCTUnwrap(rows.first { $0.model == "claude-opus-4-8" })
        XCTAssertEqual(opus.inputTokens, 11)
        XCTAssertEqual(opus.cacheCreationTokens, 22)
        XCTAssertEqual(opus.cacheReadTokens, 33)
        XCTAssertEqual(opus.outputTokens, 44)
        XCTAssertEqual(opus.bucketStart, Date(timeIntervalSince1970: 1_782_864_000)) // 2026-07-01T00:00:00Z
    }

    /// The transcripts cannot be attributed to a subscription, so nothing the
    /// reader emits may name one. This is a compile-shaped guarantee — the type has
    /// no account field at all — and this test pins the intent alongside it.
    func testEmittedRowsCarryNoAccount() throws {
        try write(
            line(model: "claude-opus-4-8", input: 10, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
        let row = try XCTUnwrap(try apply(reader.read()).first)

        XCTAssertEqual(row.model, "claude-opus-4-8")
        XCTAssertEqual(row.inputTokens, 10)
        XCTAssertEqual(row.outputTokens, 10)
        // The stored resume point is machine-wide too.
        // The reader keys the watermark by the enumerated file's path, which on
        // macOS carries the resolved `/private` prefix the temporary directory hides.
        let enumerated = try XCTUnwrap(
            FileManager.default
                .enumerator(at: directory, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { $0.pathExtension == "jsonl" }
        )
        let watermark = try XCTUnwrap(
            try ledger.fetchLocalScanWatermark(sourceKey: enumerated.path)
        )
        XCTAssertGreaterThan(watermark.byteOffset, 0)
    }

    func testSecondReadOnlyReturnsAppendedLines() throws {
        try write(
            line(model: "claude-opus-4-8", input: 10, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
        _ = try apply(reader.read())

        XCTAssertTrue(try apply(reader.read()).isEmpty, "nothing new to read")

        try append(
            line(model: "claude-opus-4-8", input: 7, cacheWrite: 0, cacheRead: 0, output: 3, timestamp: "2026-07-02T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let second = try apply(reader.read())
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.inputTokens, 7, "only the appended line, not the whole file")
    }

    /// The store *adds* what it is handed, so a second read of the same day must
    /// carry only the newly-read lines — and the two writes together must leave the
    /// ledger at the day's full total. Emitting the accumulated total again here
    /// would double-count the first read.
    func testSameDayAppendYieldsOnlyTheDeltaAndTheLedgerEndsAtTheFullTotal() throws {
        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)

        try write(
            line(model: "claude-opus-4-8", input: 100, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )
        let first = try apply(reader.read())
        XCTAssertEqual(first.first?.inputTokens, 100)

        try append(
            line(model: "claude-opus-4-8", input: 20, cacheWrite: 0, cacheRead: 0, output: 2, timestamp: "2026-07-01T09:10:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let second = try apply(reader.read())
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.inputTokens, 20, "the appended delta, not the day total read twice")
        XCTAssertEqual(second.first?.outputTokens, 2)

        let persisted = try ledger.fetchLocalTokenUsage(since: nil)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.inputTokens, 120)
        XCTAssertEqual(persisted.first?.outputTokens, 12)
    }

    func testCompletedDayIsNotReReadOnTheNextSync() throws {
        try write(
            line(model: "claude-opus-4-8", input: 10, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)

        XCTAssertEqual(try apply(reader.read()).count, 1)
        XCTAssertTrue(try apply(reader.read()).isEmpty, "a completed day is consumed once")
    }

    /// A line stamped with a day that has already closed can still be flushed after
    /// a sync has read past it — a sync running just after 00:00 UTC sees this all
    /// the time. It must land on the day it names and be added to that day's stored
    /// total, not dropped and not written over it.
    func testALineForAnAlreadyClosedDayIsAddedToThatDay() throws {
        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)

        try write(
            line(model: "claude-opus-4-8", input: 100, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )
        let first = try apply(reader.read())
        XCTAssertEqual(first.first?.inputTokens, 100)

        // Written by Claude Code a moment after the sync began, still stamped with
        // the day that was closing.
        try append(
            line(model: "claude-opus-4-8", input: 20, cacheWrite: 0, cacheRead: 0, output: 2, timestamp: "2026-07-01T23:59:59.500Z") + "\n",
            to: "session.jsonl"
        )

        let second = try apply(reader.read())

        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.bucketStart, first.first?.bucketStart, "same UTC day")
        XCTAssertEqual(second.first?.inputTokens, 20)

        let persisted = try ledger.fetchLocalTokenUsage(since: nil)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(
            persisted.first?.inputTokens,
            120,
            "the late line is added to the closed day, never written over it"
        )
    }

    /// The tolerance exists for the ledger's millisecond rounding of stored dates,
    /// which is bounded at half a millisecond. A file whose mtime moved back further
    /// than that was genuinely rewritten and must be re-read from the beginning,
    /// however similar in size it happens to be.
    func testAFileRewrittenWithinTheOldOneSecondSlackIsStillReReadFromTheStart() throws {
        try write(
            line(model: "claude-opus-4-8", input: 10, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
        XCTAssertEqual(try apply(reader.read()).count, 1)

        // Same length, mtime half a second earlier: inside the old one-second slack,
        // so the stale byte offset used to be trusted and the whole file skipped.
        let url = directory.appendingPathComponent("project-a/session.jsonl")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mTime = try XCTUnwrap(attributes[.modificationDate] as? Date)
        try FileManager.default.setAttributes(
            [.modificationDate: mTime.addingTimeInterval(-0.5)],
            ofItemAtPath: url.path
        )

        let reread = try apply(reader.read())

        XCTAssertEqual(reread.count, 1, "a rewritten file must be read from the beginning")
        XCTAssertEqual(reread.first?.inputTokens, 10)
    }

    func testTruncatedFileIsReadFromTheBeginning() throws {
        try write(
            [
                line(model: "claude-opus-4-8", input: 10, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T09:00:00.000Z"),
                line(model: "claude-opus-4-8", input: 10, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T10:00:00.000Z"),
            ].joined(separator: "\n") + "\n",
            to: "session.jsonl"
        )

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
        _ = try apply(reader.read())

        try write(
            line(model: "claude-opus-4-8", input: 1, cacheWrite: 0, cacheRead: 0, output: 1, timestamp: "2026-07-03T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let rescanned = try apply(reader.read())
        XCTAssertEqual(rescanned.first?.inputTokens, 1)
    }

    /// A trailing line still being written is left for the next pass, so it is
    /// counted exactly once — never as a truncated fragment and never twice.
    func testAPartiallyWrittenTrailingLineIsLeftForTheNextRead() throws {
        let complete = line(model: "claude-opus-4-8", input: 10, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T09:00:00.000Z")
        let pending = line(model: "claude-opus-4-8", input: 5, cacheWrite: 0, cacheRead: 0, output: 5, timestamp: "2026-07-01T10:00:00.000Z")

        try write(complete + "\n" + String(pending.prefix(30)), to: "session.jsonl")

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
        XCTAssertEqual(try apply(reader.read()).first?.inputTokens, 10)

        try append(String(pending.dropFirst(30)) + "\n", to: "session.jsonl")

        let second = try apply(reader.read())
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.inputTokens, 5, "the once-partial line is counted exactly once")
    }

    func testMalformedLinesAreSkipped() throws {
        try write(
            [
                "not json at all",
                #"{"type":"user","message":{"content":"hello"}}"#,
                line(model: "claude-opus-4-8", input: 4, cacheWrite: 0, cacheRead: 0, output: 6, timestamp: "2026-07-01T09:00:00.000Z"),
            ].joined(separator: "\n") + "\n",
            to: "session.jsonl"
        )

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
        let rows = try apply(reader.read())

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.inputTokens, 4)
    }

    func testMissingDirectoryYieldsNothingRatherThanThrowing() throws {
        let reader = ClaudeCodeLogReader(
            directory: directory.appendingPathComponent("does-not-exist", isDirectory: true),
            watermarkStore: ledger
        )

        XCTAssertTrue(try apply(reader.read()).isEmpty)
    }
}
