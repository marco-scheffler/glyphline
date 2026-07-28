import GRDB
import XCTest
@testable import Glyphline

final class ClaudeCodeLogReaderTests: XCTestCase {
    private var directory: URL!
    private var ledger: LedgerStore!
    private let accountID = UUID()

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
        let snapshots = try reader.read(accountID: accountID)

        XCTAssertEqual(snapshots.count, 2)

        let opus = try XCTUnwrap(snapshots.first { $0.model == "claude-opus-4-8" })
        XCTAssertEqual(opus.inputTokens, 11)
        XCTAssertEqual(opus.cacheCreationTokens, 22)
        XCTAssertEqual(opus.cacheReadTokens, 33)
        XCTAssertEqual(opus.outputTokens, 44)
        XCTAssertEqual(opus.quality, .partial)
        XCTAssertNil(opus.requests)
    }

    func testSecondReadOnlyReturnsAppendedLines() throws {
        try write(
            line(model: "claude-opus-4-8", input: 10, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
        _ = try reader.read(accountID: accountID)

        XCTAssertTrue(try reader.read(accountID: accountID).isEmpty, "nothing new to read")

        try append(
            line(model: "claude-opus-4-8", input: 7, cacheWrite: 0, cacheRead: 0, output: 3, timestamp: "2026-07-02T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let second = try reader.read(accountID: accountID)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.inputTokens, 7, "only the appended line, not the whole file")
    }

    /// The ledger's usage upsert replaces a bucket's totals rather than adding to
    /// them, so a snapshot must always carry the bucket's absolute total. A day that
    /// can still grow therefore stays unconsumed and is re-read in full every sync.
    func testSameDayAppendYieldsTheAccumulatedDayTotalNotTheDelta() throws {
        let reader = ClaudeCodeLogReader(
            directory: directory,
            watermarkStore: ledger,
            now: { Date(timeIntervalSince1970: 1_782_897_600) } // 2026-07-01T09:20:00Z
        )

        try write(
            line(model: "claude-opus-4-8", input: 100, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )
        let first = try reader.read(accountID: accountID)
        XCTAssertEqual(first.first?.inputTokens, 100)

        try append(
            line(model: "claude-opus-4-8", input: 20, cacheWrite: 0, cacheRead: 0, output: 2, timestamp: "2026-07-01T09:10:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let second = try reader.read(accountID: accountID)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.inputTokens, 120, "absolute day total, not just the appended delta")
        XCTAssertEqual(second.first?.outputTokens, 12)

        // And the replacing upsert therefore leaves the ledger at the full total.
        let account = Account(
            id: accountID,
            providerID: .claude,
            displayName: "Local",
            credentialReference: "local-source://claude-code",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            isEnabled: true
        )
        try ledger.saveAccount(account)
        try ledger.upsertUsageSnapshots(first)
        try ledger.upsertUsageSnapshots(second)

        let persisted = try ledger.fetchUsageSnapshots(accountID: accountID)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.inputTokens, 120)
    }

    func testCompletedDayIsNotReReadOnTheNextSync() throws {
        try write(
            line(model: "claude-opus-4-8", input: 10, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let reader = ClaudeCodeLogReader(
            directory: directory,
            watermarkStore: ledger,
            now: { Date(timeIntervalSince1970: 1_782_997_200) } // 2026-07-02T13:00:00Z
        )

        XCTAssertEqual(try reader.read(accountID: accountID).count, 1)
        XCTAssertTrue(try reader.read(accountID: accountID).isEmpty, "a completed day is consumed once")
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
        _ = try reader.read(accountID: accountID)

        try write(
            line(model: "claude-opus-4-8", input: 1, cacheWrite: 0, cacheRead: 0, output: 1, timestamp: "2026-07-03T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let rescanned = try reader.read(accountID: accountID)
        XCTAssertEqual(rescanned.first?.inputTokens, 1)
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
        let snapshots = try reader.read(accountID: accountID)

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.inputTokens, 4)
    }

    func testMissingDirectoryYieldsNothingRatherThanThrowing() throws {
        let reader = ClaudeCodeLogReader(
            directory: directory.appendingPathComponent("does-not-exist", isDirectory: true),
            watermarkStore: ledger
        )

        XCTAssertTrue(try reader.read(accountID: accountID).isEmpty)
    }
}
