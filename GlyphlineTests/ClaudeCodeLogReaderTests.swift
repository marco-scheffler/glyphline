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

    /// `id` defaults to absent, which is what most of these tests want: a record
    /// that cannot be deduplicated is counted every time it is read, so a fixture
    /// without ids behaves exactly as it did before deduplication existed.
    private func line(model: String, input: Int, cacheWrite: Int, cacheRead: Int, output: Int, timestamp: String, id: String? = nil) -> String {
        let identity = id.map { "\"id\":\"\($0)\"," } ?? ""
        return """
        {"type":"assistant","timestamp":"\(timestamp)","message":{\(identity)"model":"\(model)","usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead),"output_tokens":\(output)}}}
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
        try ledger.applyLocalScan(result)
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

        let reader = makeReader()
        let rows = try apply(reader.read())

        XCTAssertEqual(rows.count, 2)

        let opus = try XCTUnwrap(rows.first { $0.model == "claude-opus-4-8" })
        XCTAssertEqual(opus.inputTokens, 11)
        XCTAssertEqual(opus.cacheCreationTokens, 22)
        XCTAssertEqual(opus.cacheReadTokens, 33)
        XCTAssertEqual(opus.outputTokens, 44)
        XCTAssertEqual(opus.bucketStart, Date(timeIntervalSince1970: 1_782_864_000)) // 2026-07-01T00:00:00Z
    }

    /// Left to itself, the reader cuts days where the user's clock does.
    ///
    /// This is the whole defect the local grid replaced: on UTC, a Mac in Berlin
    /// began "today" at 02:00 and filed the two hours before it under yesterday
    /// — measured on one morning's real transcripts, 120M tokens where 288M had
    /// been spent.
    ///
    /// Stated against `Calendar.autoupdatingCurrent` and never against
    /// `LocalUsageDay.calendar`, which is the thing under test: an expectation
    /// written in terms of it would follow it back to UTC and pass either way.
    /// It discriminates wherever the machine's offset is not zero, which is
    /// where the defect existed.
    func testTheDefaultGridIsTheUsersOwnClock() throws {
        // Half past midnight, wherever this machine stands. Under a UTC default
        // this instant falls in the previous day for every positive offset.
        let justAfterMidnight = Calendar.autoupdatingCurrent
            .startOfDay(for: Date())
            .addingTimeInterval(30 * 60)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        stamp.timeZone = TimeZone(identifier: "UTC")

        try write(
            line(model: "claude-opus-4-8", input: 10, cacheWrite: 0, cacheRead: 0, output: 10,
                 timestamp: stamp.string(from: justAfterMidnight)) + "\n",
            to: "session.jsonl"
        )

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
        let row = try XCTUnwrap(try apply(reader.read()).first)

        XCTAssertEqual(
            row.bucketStart,
            Calendar.autoupdatingCurrent.startOfDay(for: justAfterMidnight),
            "a line stamped half an hour into the user's day belongs to that day"
        )
    }

    /// And a reader handed a calendar cuts on that one, midnight for midnight.
    ///
    /// Two lines nine hours apart, which is one UTC day and two Tokyo days.
    /// Would catch the reader forcing a timezone of its own back over the one it
    /// was given: the two lines would then merge into a single UTC bucket.
    func testADayIsCutWhereTheGivenCalendarSaysMidnightIs() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        try write(
            [
                // 18:00 in Tokyo on the 1st.
                line(model: "claude-opus-4-8", input: 10, cacheWrite: 0, cacheRead: 0, output: 0, timestamp: "2026-07-01T09:00:00.000Z"),
                // 03:00 in Tokyo on the 2nd — the same UTC day, the next Tokyo one.
                line(model: "claude-opus-4-8", input: 20, cacheWrite: 0, cacheRead: 0, output: 0, timestamp: "2026-07-01T18:00:00.000Z"),
            ].joined(separator: "\n") + "\n",
            to: "session.jsonl"
        )

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: tokyo)
        let rows = try apply(reader.read()).sorted { $0.bucketStart < $1.bucketStart }

        XCTAssertEqual(rows.count, 2, "one UTC day is two days in Tokyo")
        XCTAssertEqual(rows[0].bucketStart, Date(timeIntervalSince1970: 1_782_831_600)) // 2026-06-30T15:00:00Z
        XCTAssertEqual(rows[0].inputTokens, 10)
        XCTAssertEqual(rows[1].bucketStart, Date(timeIntervalSince1970: 1_782_918_000)) // 2026-07-01T15:00:00Z
        XCTAssertEqual(rows[1].inputTokens, 20)
    }

    /// The transcripts cannot be attributed to a subscription, so nothing the
    /// reader emits may name one. This is a compile-shaped guarantee — the type has
    /// no account field at all — and this test pins the intent alongside it.
    func testEmittedRowsCarryNoAccount() throws {
        try write(
            line(model: "claude-opus-4-8", input: 10, cacheWrite: 0, cacheRead: 0, output: 10, timestamp: "2026-07-01T09:00:00.000Z") + "\n",
            to: "session.jsonl"
        )

        let reader = makeReader()
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

        let reader = makeReader()
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
        let reader = makeReader()

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

        let reader = makeReader()

        XCTAssertEqual(try apply(reader.read()).count, 1)
        XCTAssertTrue(try apply(reader.read()).isEmpty, "a completed day is consumed once")
    }

    /// A line stamped with a day that has already closed can still be flushed after
    /// a sync has read past it — a sync running just after 00:00 UTC sees this all
    /// the time. It must land on the day it names and be added to that day's stored
    /// total, not dropped and not written over it.
    func testALineForAnAlreadyClosedDayIsAddedToThatDay() throws {
        let reader = makeReader()

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

        let reader = makeReader()
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

        let reader = makeReader()
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

        let reader = makeReader()
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

        let reader = makeReader()
        let rows = try apply(reader.read())

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.inputTokens, 4)
    }

    /// Claude Code writes `<synthetic>` for assistant turns it produced itself —
    /// an error notice, an interrupt. That is not a model, so it must not become
    /// a row that can never be priced.
    func testSyntheticPlaceholderModelIsNotRecorded() throws {
        try write(
            [
                line(model: "<synthetic>", input: 0, cacheWrite: 0, cacheRead: 0, output: 0, timestamp: "2026-07-01T09:00:00.000Z"),
                line(model: "claude-opus-4-8", input: 4, cacheWrite: 0, cacheRead: 0, output: 6, timestamp: "2026-07-01T09:30:00.000Z"),
            ].joined(separator: "\n") + "\n",
            to: "session.jsonl"
        )

        let reader = makeReader()
        let rows = try apply(reader.read())

        XCTAssertEqual(rows.map(\.model), ["claude-opus-4-8"])
    }

    func testMissingDirectoryYieldsNothingRatherThanThrowing() throws {
        let reader = ClaudeCodeLogReader(
            directory: directory.appendingPathComponent("does-not-exist", isDirectory: true),
            watermarkStore: ledger
        )

        XCTAssertTrue(try apply(reader.read()).isEmpty)
    }

    /// The grid every test below fixes so it can talk about something else.
    ///
    /// UTC, which is what makes the `…T09:00:00.000Z` fixtures and the expected
    /// bucket instants readable as the same day. Production cuts days on the
    /// user's clock instead — `testTheDefaultGridIsTheUsersOwnClock` and
    /// `testADayIsCutWhereTheGivenCalendarSaysMidnightIs` are the two that hold
    /// *that*, and they are the only ones here that may name a timezone.
    private let fixedGrid: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private func makeReader() -> ClaudeCodeLogReader {
        ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: fixedGrid)
    }

    /// The existing `line` helper omits `sessionId`, and several tests depend on
    /// exactly the shape it produces. This is the same record with the field the
    /// session totals are keyed on.
    private func sessionLine(
        session: String,
        model: String,
        input: Int,
        output: Int,
        timestamp: String
    ) -> String {
        """
        {"type":"assistant","sessionId":"\(session)","timestamp":"\(timestamp)",\
        "message":{"model":"\(model)","usage":{"input_tokens":\(input),\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0,\
        "output_tokens":\(output)}}}
        """
    }

    private func sessionTotals(_ result: LocalScanResult) -> [String: Int64] {
        Dictionary(
            result.sessionUsage.map { ($0.sessionID, $0.totalTokens) },
            uniquingKeysWith: +
        )
    }

    func testTokensAreTotalledPerSession() throws {
        try write(
            sessionLine(session: "S1", model: "sonnet", input: 10, output: 5,
                        timestamp: "2026-07-30T10:00:00.000Z") + "\n" +
            sessionLine(session: "S2", model: "sonnet", input: 100, output: 50,
                        timestamp: "2026-07-30T10:01:00.000Z") + "\n",
            to: "a.jsonl"
        )

        let totals = sessionTotals(try makeReader().read())

        XCTAssertEqual(totals["S1"], 15)
        XCTAssertEqual(totals["S2"], 150)
    }

    /// A subagent transcript carries its parent's sessionId and lives under a
    /// different project slug. Its tokens belong to the parent session, which is
    /// what makes a session's lap count mean what it consumed in total.
    func testASubagentTranscriptTotalsIntoItsParentSession() throws {
        try write(
            sessionLine(session: "S1", model: "sonnet", input: 10, output: 5,
                        timestamp: "2026-07-30T10:00:00.000Z") + "\n",
            to: "main.jsonl"
        )
        try write(
            sessionLine(session: "S1", model: "sonnet", input: 200, output: 100,
                        timestamp: "2026-07-30T10:02:00.000Z") + "\n",
            to: "agent.jsonl"
        )

        XCTAssertEqual(sessionTotals(try makeReader().read())["S1"], 315)
    }

    /// Keyed per model like the daily totals, so the figures stay priceable.
    func testASessionIsBrokenDownByModel() throws {
        try write(
            sessionLine(session: "S1", model: "sonnet", input: 10, output: 0,
                        timestamp: "2026-07-30T10:00:00.000Z") + "\n" +
            sessionLine(session: "S1", model: "opus", input: 7, output: 0,
                        timestamp: "2026-07-30T10:01:00.000Z") + "\n",
            to: "a.jsonl"
        )

        let rows = try makeReader().read().sessionUsage
            .filter { $0.sessionID == "S1" }
            .sorted { ($0.model ?? "") < ($1.model ?? "") }

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].model, "opus")
        XCTAssertEqual(rows[0].totalTokens, 7)
        XCTAssertEqual(rows[1].model, "sonnet")
        XCTAssertEqual(rows[1].totalTokens, 10)
    }

    /// The session analogue of `testSameDayAppendYieldsOnlyTheDeltaAndTheLedgerEndsAtTheFullTotal`.
    /// The reader emits only what it has newly read and the store adds it, so the
    /// two halves must meet at the full total. A store that replaced instead of
    /// added would leave the session showing the second read alone, and every
    /// other session test does a single read and would stay green through it.
    func testASecondReadOfTheSameSessionLeavesTheStoredTotalAtTheFullSum() throws {
        let reader = makeReader()

        try write(
            sessionLine(session: "S1", model: "sonnet", input: 100, output: 10,
                        timestamp: "2026-07-30T10:00:00.000Z") + "\n",
            to: "a.jsonl"
        )
        try ledger.applyLocalScan(try reader.read())
        XCTAssertEqual(try ledger.fetchSessionTokens(sessionIDs: ["S1"])["S1"], 110)

        try append(
            sessionLine(session: "S1", model: "sonnet", input: 20, output: 2,
                        timestamp: "2026-07-30T10:05:00.000Z") + "\n",
            to: "a.jsonl"
        )

        let second = try reader.read()
        XCTAssertEqual(
            second.sessionUsage.first { $0.sessionID == "S1" }?.totalTokens, 22,
            "the reader hands over the appended lines alone"
        )

        try ledger.applyLocalScan(second)

        XCTAssertEqual(
            try ledger.fetchSessionTokens(sessionIDs: ["S1"])["S1"], 132,
            "both reads, added once each — not the second one on its own"
        )
    }

    /// A record with no session id still counts toward the day. It must not be
    /// gathered under a placeholder id — a sentinel would be read as a session
    /// by the next person to look.
    func testARecordWithoutASessionCountsForTheDayAndNoSession() throws {
        try write(
            line(model: "sonnet", input: 10, cacheWrite: 0, cacheRead: 0, output: 5,
                 timestamp: "2026-07-30T10:00:00.000Z") + "\n",
            to: "a.jsonl"
        )

        let result = try makeReader().read()

        XCTAssertEqual(result.usage.first?.totalTokens, 15, "the day still sees it")
        XCTAssertTrue(result.sessionUsage.isEmpty)
    }

    /// The bug this task exists for, stated as a test.
    ///
    /// Resuming or forking a session makes Claude Code write a *new* transcript
    /// with the preceding history copied into it, so the same assistant message —
    /// same id, same usage block — sits in both files. The naive per-line sum
    /// counts it twice.
    ///
    /// Scanned in two passes on purpose: that is the shape the per-file
    /// watermarks force. The parent was fully consumed in the first pass, the
    /// fork is new in the second and is read from byte zero, so a set living only
    /// for one scan would not remember M1 or M2 at all.
    func testAMessageCopiedIntoAForkedTranscriptIsCountedOnce() throws {
        let parent = [
            line(model: "sonnet", input: 100, cacheWrite: 0, cacheRead: 0, output: 10,
                 timestamp: "2026-07-30T10:00:00.000Z", id: "msg_1"),
            line(model: "sonnet", input: 200, cacheWrite: 0, cacheRead: 0, output: 20,
                 timestamp: "2026-07-30T10:05:00.000Z", id: "msg_2"),
        ].joined(separator: "\n") + "\n"

        try write(parent, to: "parent.jsonl")
        try ledger.applyLocalScan(try makeReader().read())

        // The fork: the parent's history copied verbatim, then one new turn.
        try write(
            parent + line(model: "sonnet", input: 5, cacheWrite: 0, cacheRead: 0, output: 1,
                          timestamp: "2026-07-30T10:10:00.000Z", id: "msg_3") + "\n",
            to: "fork.jsonl"
        )
        try ledger.applyLocalScan(try makeReader().read())

        let total = try ledger.fetchLocalTokenUsage(since: nil)
            .reduce(Int64(0)) { $0 + $1.totalTokens }
        XCTAssertEqual(
            total, 336,
            "msg_1 + msg_2 + msg_3 counted once each; the naive per-line sum is 666"
        )
    }

    /// The same bug on a fresh install, which is a different code path.
    ///
    /// On a first run nothing is persisted and every file is new, so one scan
    /// sees the parent and the fork *together*. Nothing in the table catches the
    /// copy — only the `seen` set growing as the scan counts does. The two-pass
    /// test above cannot reach that path, because there the parent's ids come
    /// back from the ledger.
    func testAMessageCopiedIntoAForkIsCountedOnceWhenBothAreScannedInOnePass() throws {
        let parent = [
            line(model: "sonnet", input: 100, cacheWrite: 0, cacheRead: 0, output: 10,
                 timestamp: "2026-07-30T10:00:00.000Z", id: "msg_1"),
            line(model: "sonnet", input: 200, cacheWrite: 0, cacheRead: 0, output: 20,
                 timestamp: "2026-07-30T10:05:00.000Z", id: "msg_2"),
        ].joined(separator: "\n") + "\n"

        try write(parent, to: "parent.jsonl")
        try write(
            parent + line(model: "sonnet", input: 5, cacheWrite: 0, cacheRead: 0, output: 1,
                          timestamp: "2026-07-30T10:10:00.000Z", id: "msg_3") + "\n",
            to: "fork.jsonl"
        )

        try ledger.applyLocalScan(try makeReader().read())

        let total = try ledger.fetchLocalTokenUsage(since: nil)
            .reduce(Int64(0)) { $0 + $1.totalTokens }
        XCTAssertEqual(
            total, 336,
            "one pass over both files, msg_1 + msg_2 + msg_3 once each; naive is 666"
        )
    }

    /// The guard must not swallow real usage: an id nobody has counted yet is
    /// counted, however late it turns up.
    func testANewMessageIDInALaterScanIsStillCounted() throws {
        try write(
            line(model: "sonnet", input: 100, cacheWrite: 0, cacheRead: 0, output: 0,
                 timestamp: "2026-07-30T10:00:00.000Z", id: "msg_1") + "\n",
            to: "a.jsonl"
        )
        try ledger.applyLocalScan(try makeReader().read())

        try append(
            line(model: "sonnet", input: 7, cacheWrite: 0, cacheRead: 0, output: 0,
                 timestamp: "2026-07-30T11:00:00.000Z", id: "msg_2") + "\n",
            to: "a.jsonl"
        )
        let second = try makeReader().read()

        XCTAssertEqual(second.usage.first?.totalTokens, 7, "the new message is not suppressed")
        XCTAssertEqual(second.seenMessages.map(\.messageID), ["msg_2"])
    }

    /// A record with no `message.id` cannot be deduplicated, so it is counted —
    /// and counted again if the same content recurs in a fork. That is the
    /// accepted limit of this fix, pinned here so it stays deliberate: dropping
    /// usage that cannot be identified would trade the over-count for an
    /// under-count nothing would ever reveal.
    func testARecordWithoutAMessageIDIsCountedEveryTimeItIsSeen() throws {
        let anonymous = line(model: "sonnet", input: 100, cacheWrite: 0, cacheRead: 0,
                             output: 0, timestamp: "2026-07-30T10:00:00.000Z") + "\n"

        try write(anonymous, to: "parent.jsonl")
        try ledger.applyLocalScan(try makeReader().read())
        try write(anonymous, to: "fork.jsonl")
        let second = try makeReader().read()

        XCTAssertEqual(second.usage.first?.totalTokens, 100, "counted again, knowingly")
        XCTAssertTrue(second.seenMessages.isEmpty, "there is no id to remember it by")
    }
}
