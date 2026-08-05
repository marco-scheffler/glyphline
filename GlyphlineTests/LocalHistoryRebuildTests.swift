import GRDB
import XCTest
@testable import Glyphline

/// The grid these fixtures are cut on.
///
/// Fixed on UTC so that the seeded `bucketStart` and the day the reader derives
/// from a `…T09:00:00.000Z` line are the same day wherever the suite runs.
/// Production cuts on the user's clock; what these tests are about is the
/// coverage rule that decides whether a day may be replaced, which no timezone
/// should be able to change. `ClaudeCodeLogReaderTests` holds the grid itself.
private let fixedGrid: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}()

/// The per-day decision, as pure arithmetic over two numbers — no database, no
/// transcripts, the way `AppActivationController.policy(for:hasWindowNeedingRegularApp:)`
/// made an activation decision testable without driving `NSApp`.
final class LocalHistoryRebuildDecisionTests: XCTestCase {
    func testFullCoverageReplaces() {
        XCTAssertTrue(
            LocalHistoryRebuild.shouldReplace(recorded: 1_000, naiveFromSurvivingFiles: 1_000),
            "the surviving files reproduce the recorded figure exactly"
        )
    }

    func testPartialCoverageKeeps() {
        XCTAssertFalse(
            LocalHistoryRebuild.shouldReplace(recorded: 1_000, naiveFromSurvivingFiles: 500),
            "half the day's files are gone; the recorded figure is the better evidence"
        )
    }

    func testCoverageAboveOneReplaces() {
        // 2026-08-03 on the reference machine: 119.7%, a partial day the scanner
        // had not finished when it last wrote.
        XCTAssertTrue(
            LocalHistoryRebuild.shouldReplace(recorded: 1_000, naiveFromSurvivingFiles: 1_197)
        )
    }

    func testZeroCoverageKeeps() {
        // 2026-06-29 on the reference machine: 4 Gtok recorded, nothing left to
        // read. This is the case that a blanket rescan would have zeroed.
        XCTAssertFalse(
            LocalHistoryRebuild.shouldReplace(
                recorded: 4_000_000_000,
                naiveFromSurvivingFiles: 0
            )
        )
    }

    func testExactlyAtTheThresholdReplaces() {
        XCTAssertTrue(
            LocalHistoryRebuild.shouldReplace(recorded: 10_000, naiveFromSurvivingFiles: 9_700)
        )
        XCTAssertFalse(
            LocalHistoryRebuild.shouldReplace(recorded: 10_000, naiveFromSurvivingFiles: 9_699),
            "just under the threshold is a day with files missing"
        )
    }

    /// A day with no recorded figure is new data, not a correction. No ratio is
    /// invented against zero.
    func testNothingRecordedIsNotAReplacement() {
        XCTAssertFalse(
            LocalHistoryRebuild.shouldReplace(recorded: 0, naiveFromSurvivingFiles: 500)
        )
    }
}

/// The end-to-end shape: fixture transcripts, a temporary ledger, and the
/// controller's one-shot marker.
@MainActor
final class LocalHistoryRebuildEndToEndTests: XCTestCase {
    private var directory: URL!
    private var ledger: LedgerStore!

    /// 2026-07-01T00:00:00Z, the UTC day every fixture line falls in.
    private let day = Date(timeIntervalSince1970: 1_782_864_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glyphline-rebuild-\(UUID().uuidString)", isDirectory: true)
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

    private func line(id: String, input: Int, at timestamp: String) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","message":{"id":"\(id)","model":"claude-opus-4-8","usage":{"input_tokens":\(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        """
    }

    private func write(_ lines: [String], to name: String) throws {
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("project-a/\(name)"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// A parent transcript and a fork that copies its prefix. Three distinct
    /// messages, 300 tokens deduplicated; the old scanner counted five lines and
    /// recorded 500.
    private func writeParentAndFork() throws {
        try write(
            [
                line(id: "msg-1", input: 100, at: "2026-07-01T09:00:00.000Z"),
                line(id: "msg-2", input: 100, at: "2026-07-01T10:00:00.000Z"),
            ],
            to: "parent.jsonl"
        )
        try write(
            [
                line(id: "msg-1", input: 100, at: "2026-07-01T09:00:00.000Z"),
                line(id: "msg-2", input: 100, at: "2026-07-01T10:00:00.000Z"),
                line(id: "msg-3", input: 100, at: "2026-07-01T11:00:00.000Z"),
            ],
            to: "fork.jsonl"
        )
    }

    private func seedInflatedHistory(_ tokens: Int64) throws {
        try ledger.upsertLocalTokenUsage([
            LocalTokenUsage(bucketStart: day, model: "claude-opus-4-8", inputTokens: tokens),
        ])
    }

    @discardableResult
    private func runRebuild() throws -> Bool {
        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: fixedGrid)
        return try ledger.applyLocalHistoryRebuild(reader.readForRebuild())
    }

    private func recordedTotal() throws -> Int64 {
        try ledger.fetchLocalTokenUsage(since: nil).reduce(0) { $0 + $1.totalTokens }
    }

    func testReplacesAnInflatedDayWithTheDeduplicatedTotal() throws {
        try writeParentAndFork()
        try seedInflatedHistory(500)

        try runRebuild()

        XCTAssertEqual(
            try recordedTotal(), 300,
            "the surviving files reproduce the recorded 500 naively, so the day is replaced"
        )
    }

    /// The test that matters. The parent's file is gone — as 372 of them were on
    /// the reference machine — so the surviving fork accounts for only 300 of the
    /// recorded 500. The recorded figure stands.
    func testKeepsTheRecordedFigureWhenFilesAreMissing() throws {
        try write(
            [
                line(id: "msg-1", input: 100, at: "2026-07-01T09:00:00.000Z"),
                line(id: "msg-2", input: 100, at: "2026-07-01T10:00:00.000Z"),
                line(id: "msg-3", input: 100, at: "2026-07-01T11:00:00.000Z"),
            ],
            to: "fork.jsonl"
        )
        try seedInflatedHistory(500)

        try runRebuild()

        XCTAssertEqual(
            try recordedTotal(), 500,
            "coverage is 0.6; dropping to the fork's partial view would destroy real usage"
        )
    }

    /// A day recorded with nothing at all left to read keeps its figure — the
    /// 4 Gtok case.
    func testKeepsADayWithNoSurvivingTranscriptsAtAll() throws {
        try seedInflatedHistory(4_000_000)

        try runRebuild()

        XCTAssertEqual(try recordedTotal(), 4_000_000)
    }

    func testPopulatesSeenMessagesSoTheNextForkDoesNotDoubleCount() throws {
        try writeParentAndFork()
        try seedInflatedHistory(500)

        try runRebuild()

        XCTAssertEqual(
            try ledger.fetchSeenMessageIDs(),
            ["msg-1", "msg-2", "msg-3"],
            "every counted id must survive the rebuild, or the next fork re-inflates"
        )
    }

    /// After the rebuild the ordinary scan has nothing left to add — the
    /// watermarks landed with the rows.
    func testTheOrdinaryScanAddsNothingAfterARebuild() throws {
        try writeParentAndFork()
        try seedInflatedHistory(500)
        try runRebuild()

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: fixedGrid)
        try ledger.applyLocalScan(reader.read())

        XCTAssertEqual(try recordedTotal(), 300)
    }

    func testAFreshInstallRebuildsNothing() throws {
        try writeParentAndFork()

        try runRebuild()

        XCTAssertEqual(
            try recordedTotal(), 300,
            "nothing was recorded, so the deduplicated rows are an insert rather than a correction"
        )
    }

    /// The rebuild gathers session totals too, deduplicated, alongside the naive
    /// per-session sum its coverage rule needs.
    func testTheRebuildGathersSessionTotalsAndTheirNaiveSum() throws {
        try write(
            [
                """
                {"type":"assistant","sessionId":"session-1","timestamp":"2026-07-01T09:00:00.000Z","message":{"id":"msg-1","model":"claude-opus-4-8","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
                """,
            ],
            to: "session.jsonl"
        )

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: fixedGrid)
        let rebuild = try reader.readForRebuild()
        XCTAssertEqual(rebuild.scan.sessionUsage.count, 1)
        XCTAssertEqual(rebuild.naiveSessionTotals, ["session-1": 100])
    }

    // MARK: - The rebuild against the ordinary scan

    /// The collision the whole gate exists for. The ordinary launch scan starts
    /// first and is slow — it walks thousands of files — so it reads before the
    /// rebuild commits and would write after it. `applyLocalScan` accumulates, so
    /// without the gate its 300 lands on top of the 300 the rebuild has just
    /// replaced the inflated 500 with, and the day is inflated all over again on
    /// exactly the installation this feature exists to correct.
    func testTheOrdinaryScanCannotAddOnTopOfTheRebuild() async throws {
        try writeParentAndFork()
        try seedInflatedHistory(500)

        let ledger = ledger!
        let directory = directory!
        let gate = LocalHistoryWriteGate(rebuildIsOutstanding: true)

        // Started first, and deliberately slow between reading and writing.
        let scan = Task {
            await gate.runScan {
                let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: fixedGrid)
                let result = try reader.read()
                Thread.sleep(forTimeInterval: 0.2)
                try ledger.applyLocalScan(result)
            }
        }

        let rebuild = Task {
            await gate.runRebuild {
                let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: fixedGrid)
                return try ledger.applyLocalHistoryRebuild(reader.readForRebuild())
            }
        }

        _ = await rebuild.value
        _ = await scan.value

        XCTAssertEqual(
            try recordedTotal(), 300,
            "the scan must not add its totals on top of the day the rebuild replaced"
        )
    }

    /// The deadlock the gate could otherwise reach. `GlyphlineApp.init` arms the
    /// gate from the durable markers, but the rebuild controller declines to run
    /// when there is no ledger — and a gate armed with nobody left to open it
    /// suspends every `runScan` forever, so local usage silently never updates
    /// again with no error and no bound. The controller must open the gate on
    /// every path where it declines. Expectation rather than a bare `await`, so
    /// the regression fails this test instead of hanging the suite.
    func testDecliningToRebuildOpensTheGateForOrdinaryScans() async {
        let settings = makeSettings()
        XCTAssertFalse(settings.hasRebuiltLocalHistory)
        XCTAssertFalse(settings.hasRebuiltLocalSessionTokens)

        // Armed exactly as `GlyphlineApp.init` arms it from those markers.
        let gate = LocalHistoryWriteGate(rebuildIsOutstanding: true)
        // No ledger: the controller declines, and nothing else can ever open the
        // gate.
        let controller = LocalHistoryRebuildController(
            settings: settings, gate: gate, ledger: nil
        )

        let scanned = expectation(description: "the ordinary scan ran")
        Task {
            _ = await gate.runScan { scanned.fulfill() }
        }
        await fulfillment(of: [scanned], timeout: 5)

        await controller.task?.value
        XCTAssertFalse(
            settings.hasRebuiltLocalHistory,
            "declining to rebuild must not spend the single shot"
        )
    }

    // MARK: - The marker

    private func makeSettings() -> AppSettingsStore {
        let defaults = UserDefaults(suiteName: "glyphline-rebuild-\(UUID().uuidString)")!
        return AppSettingsStore(defaults: defaults)
    }

    private func makeGate() -> LocalHistoryWriteGate {
        LocalHistoryWriteGate(rebuildIsOutstanding: true)
    }

    func testTheRebuildRunsOnceAndMarksItself() async {
        let settings = makeSettings()
        let runs = RebuildRunCounter()

        let first = LocalHistoryRebuildController(settings: settings, gate: makeGate()) {
            runs.increment()
            return true
        }
        await first.task?.value

        XCTAssertEqual(runs.value, 1)
        XCTAssertTrue(settings.hasRebuiltLocalHistory)

        let second = LocalHistoryRebuildController(settings: settings, gate: makeGate()) {
            runs.increment()
            return true
        }
        await second.task?.value

        XCTAssertEqual(runs.value, 1, "a rebuild that runs on every launch is a performance bug")
    }

    /// An empty history still marks done: there is nothing to correct on a fresh
    /// install, and re-reading every transcript on every launch to discover that
    /// again is the bug the marker exists to prevent.
    func testAnEmptyHistoryStillMarksDone() async throws {
        try writeParentAndFork()
        let settings = makeSettings()
        let ledger = ledger!
        let directory = directory!

        let controller = LocalHistoryRebuildController(settings: settings, gate: makeGate()) {
            let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: fixedGrid)
            return try ledger.applyLocalHistoryRebuild(reader.readForRebuild())
        }
        await controller.task?.value

        XCTAssertTrue(settings.hasRebuiltLocalHistory)
    }

    /// Nothing recorded and nothing to read is not a failure — there is nothing to
    /// correct, so the single shot is spent rather than retried forever.
    func testAGenuinelyEmptyInstallMarksDoneWithNoTranscriptsAtAll() throws {
        XCTAssertTrue(try runRebuild())
        XCTAssertEqual(try recordedTotal(), 0)
    }

    /// The single shot must not be burned on a launch that read nothing while
    /// there was a history to correct — an unmounted volume, an unanswered
    /// permissions prompt, a machine mid-restore. `transcriptURLs()` returns an
    /// empty list for an unreadable directory rather than throwing, so nothing
    /// else would notice.
    func testAnUnreadableTranscriptDirectoryDoesNotSpendTheSingleShot() async throws {
        try seedInflatedHistory(500)

        let settings = makeSettings()
        let ledger = ledger!
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("glyphline-absent-\(UUID().uuidString)", isDirectory: true)

        let controller = LocalHistoryRebuildController(settings: settings, gate: makeGate()) {
            let reader = ClaudeCodeLogReader(directory: absent, watermarkStore: ledger, calendar: fixedGrid)
            return try ledger.applyLocalHistoryRebuild(reader.readForRebuild())
        }
        await controller.task?.value

        XCTAssertFalse(
            settings.hasRebuiltLocalHistory,
            "a launch that could not read the transcripts must leave the rebuild to the next one"
        )
        XCTAssertEqual(try recordedTotal(), 500, "and it must not have touched the history")
    }

    /// A failed rebuild leaves the marker unset, so the next launch tries again —
    /// the transaction means nothing of it landed.
    func testAFailedRebuildIsNotMarkedDone() async {
        let settings = makeSettings()

        struct Boom: Error {}
        let controller = LocalHistoryRebuildController(settings: settings, gate: makeGate()) {
            throw Boom()
        }
        await controller.task?.value

        XCTAssertFalse(settings.hasRebuiltLocalHistory)
    }
}

/// The per-session half of the same rebuild: the same coverage rule, grouped by
/// `sessionId` instead of by day, under a marker of its own.
///
/// This is what `AgentverseCoordinator` reads through `fetchSessionWorkTokens`
/// for the per-agent token column, so every one of these figures is on screen.
@MainActor
final class LocalSessionTokenRebuildTests: XCTestCase {
    private var directory: URL!
    private var ledger: LedgerStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glyphline-session-rebuild-\(UUID().uuidString)", isDirectory: true)
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

    private func line(id: String, session: String?, input: Int, at timestamp: String) -> String {
        let sessionField = session.map { "\"sessionId\":\"\($0)\"," } ?? ""
        return """
        {"type":"assistant",\(sessionField)"timestamp":"\(timestamp)","message":{"id":"\(id)","model":"claude-opus-4-8","usage":{"input_tokens":\(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        """
    }

    private func write(_ lines: [String], to name: String) throws {
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("project-a/\(name)"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// The fork that caused all this. Both files carry the same `sessionId` — a
    /// resume copies the session's history into a new file — so the old scanner
    /// counted five lines for one session and recorded 500 where 300 were real.
    private func writeParentAndFork() throws {
        try write(
            [
                line(id: "msg-1", session: "session-1", input: 100, at: "2026-07-01T09:00:00.000Z"),
                line(id: "msg-2", session: "session-1", input: 100, at: "2026-07-01T10:00:00.000Z"),
            ],
            to: "parent.jsonl"
        )
        try writeFork()
    }

    private func writeFork() throws {
        try write(
            [
                line(id: "msg-1", session: "session-1", input: 100, at: "2026-07-01T09:00:00.000Z"),
                line(id: "msg-2", session: "session-1", input: 100, at: "2026-07-01T10:00:00.000Z"),
                line(id: "msg-3", session: "session-1", input: 100, at: "2026-07-01T11:00:00.000Z"),
            ],
            to: "fork.jsonl"
        )
    }

    private func seedInflatedSession(_ tokens: Int64, sessionID: String = "session-1") throws {
        try ledger.applyLocalScan(
            LocalScanResult(
                usage: [],
                sessionUsage: [
                    LocalSessionTokenUsage(
                        sessionID: sessionID, model: "claude-opus-4-8", inputTokens: tokens
                    ),
                ],
                watermarks: []
            )
        )
    }

    @discardableResult
    private func runRebuild() throws -> Bool {
        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: fixedGrid)
        return try ledger.applyLocalSessionTokenRebuild(reader.readForRebuild())
    }

    private func recordedTotal(_ sessionID: String = "session-1") throws -> Int64 {
        try ledger.fetchSessionTokens(sessionIDs: [sessionID])[sessionID] ?? 0
    }

    // MARK: - The coverage rule, per session

    func testFullCoverageReplacesTheInflatedSession() throws {
        try writeParentAndFork()
        try seedInflatedSession(500)

        try runRebuild()

        XCTAssertEqual(
            try recordedTotal(), 300,
            "the surviving files reproduce the recorded 500 naively, so the session is replaced"
        )
    }

    /// The test that matters, and the per-session twin of the 4 Gtok case. The
    /// parent's file is gone — as the `subagents/agent-*.jsonl` transcripts are on
    /// every machine that has updated Claude Code — so the surviving fork accounts
    /// for only 300 of the recorded 500. The recorded figure stands.
    ///
    /// A blanket rebuild that ignores coverage turns this red at 300.
    func testKeepsTheRecordedFigureWhenFilesAreMissing() throws {
        try writeFork()
        try seedInflatedSession(500)

        try runRebuild()

        XCTAssertEqual(
            try recordedTotal(), 500,
            "coverage is 0.6; dropping to the fork's partial view would destroy real usage"
        )
    }

    /// Nothing at all left to read for a recorded session: it never appears in the
    /// scan's rows, so it is untouched by construction rather than zeroed.
    func testKeepsASessionWithNoSurvivingTranscriptsAtAll() throws {
        try seedInflatedSession(4_000_000)

        try runRebuild()

        XCTAssertEqual(try recordedTotal(), 4_000_000)
    }

    /// Coverage above 1.0 is a session the scanner had not finished recording, and
    /// must replace like any other.
    func testCoverageAboveOneReplaces() throws {
        try writeParentAndFork()
        try seedInflatedSession(418)

        try runRebuild()

        XCTAssertEqual(
            try recordedTotal(), 300,
            "500 naive against 418 recorded is 119.7% — a partial write, not a missing file"
        )
    }

    /// A session with no recorded figure is new data, not a correction; no ratio
    /// is computed against zero and the rows are inserted.
    func testASessionWithNothingRecordedIsInserted() throws {
        try writeParentAndFork()

        try runRebuild()

        XCTAssertEqual(try recordedTotal(), 300)
    }

    /// Records without a `sessionId` belong to no session and simply do not
    /// participate — neither in the rows nor in the naive sums.
    func testRecordsWithoutASessionIDDoNotParticipate() throws {
        try write(
            [
                line(id: "msg-1", session: nil, input: 100, at: "2026-07-01T09:00:00.000Z"),
                line(id: "msg-2", session: "session-1", input: 100, at: "2026-07-01T10:00:00.000Z"),
            ],
            to: "mixed.jsonl"
        )

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: fixedGrid)
        let rebuild = try reader.readForRebuild()
        XCTAssertEqual(rebuild.naiveSessionTotals, ["session-1": 100])

        try ledger.applyLocalSessionTokenRebuild(rebuild)
        XCTAssertEqual(try recordedTotal(), 100, "only the record that named a session counts")
    }

    // MARK: - Against the ordinary scan

    /// The same collision the gate exists for, on the session rows: the ordinary
    /// scan's `addLocalSessionTokens` accumulates, so a scan that reads before the
    /// rebuild commits and writes after it would put its 300 on top of the 300 the
    /// rebuild has just written and re-inflate the very column this fixes.
    func testTheOrdinaryScanCannotAddOnTopOfTheSessionRebuild() async throws {
        try writeParentAndFork()
        try seedInflatedSession(500)

        let ledger = ledger!
        let directory = directory!
        let gate = LocalHistoryWriteGate(rebuildIsOutstanding: true)

        let scan = Task {
            await gate.runScan {
                let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: fixedGrid)
                let result = try reader.read()
                Thread.sleep(forTimeInterval: 0.2)
                try ledger.applyLocalScan(result)
            }
        }

        let rebuild = Task {
            await gate.runRebuild {
                let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: fixedGrid)
                let scanned = try reader.readForRebuild()
                let days = try ledger.applyLocalHistoryRebuild(scanned)
                let sessions = try ledger.applyLocalSessionTokenRebuild(scanned)
                return days && sessions
            }
        }

        _ = await rebuild.value
        _ = await scan.value

        XCTAssertEqual(
            try recordedTotal(), 300,
            "the scan must not add its totals on top of the session the rebuild replaced"
        )
    }

    // MARK: - The marker

    private func makeSettings() -> AppSettingsStore {
        let defaults = UserDefaults(suiteName: "glyphline-session-rebuild-\(UUID().uuidString)")!
        return AppSettingsStore(defaults: defaults)
    }

    private func makeGate() -> LocalHistoryWriteGate {
        LocalHistoryWriteGate(rebuildIsOutstanding: true)
    }

    /// The property the whole second marker exists for. 1.5 shipped and set
    /// `hasRebuiltLocalHistory` on every machine that launched it, so a session
    /// rebuild hung on that marker would never run for the users who need it.
    func testRunsEvenWhereTheDayRebuildHasAlreadyRun() async throws {
        let settings = makeSettings()
        settings.hasRebuiltLocalHistory = true
        XCTAssertFalse(settings.hasRebuiltLocalSessionTokens)

        try writeParentAndFork()
        try seedInflatedSession(500)

        let ledger = ledger!
        let directory = directory!
        let controller = LocalHistoryRebuildController(
            settings: settings, gate: makeGate(), ledger: ledger, directory: directory
        )
        await controller.task?.value

        XCTAssertTrue(settings.hasRebuiltLocalSessionTokens)
        XCTAssertEqual(try recordedTotal(), 300, "the session half ran on its own")
    }

    /// And it runs once. Re-reading every transcript on every launch is the
    /// performance bug the marker exists to prevent.
    func testTheSessionRebuildRunsOnce() async {
        let settings = makeSettings()
        settings.hasRebuiltLocalHistory = true
        let runs = RebuildRunCounter()

        let first = LocalHistoryRebuildController(settings: settings, gate: makeGate()) {
            runs.increment()
            return true
        }
        await first.task?.value
        XCTAssertEqual(runs.value, 1)
        XCTAssertTrue(settings.hasRebuiltLocalSessionTokens)

        let second = LocalHistoryRebuildController(settings: settings, gate: makeGate()) {
            runs.increment()
            return true
        }
        await second.task?.value

        XCTAssertEqual(runs.value, 1)
    }

    /// A crash mid-rebuild leaves both the figures and the marker untouched, so
    /// the next launch simply runs it again.
    func testACrashMidRebuildLeavesTheFiguresAndTheMarkerUntouched() async throws {
        try writeParentAndFork()
        try seedInflatedSession(500)

        let settings = makeSettings()
        settings.hasRebuiltLocalHistory = true
        let ledger = ledger!
        let directory = directory!

        struct Boom: Error {}
        let controller = LocalHistoryRebuildController(settings: settings, gate: makeGate()) {
            let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger, calendar: fixedGrid)
            _ = try reader.readForRebuild()
            throw Boom()
        }
        await controller.task?.value

        XCTAssertFalse(settings.hasRebuiltLocalSessionTokens)
        XCTAssertEqual(try recordedTotal(), 500, "nothing of an interrupted rebuild lands")
    }

    /// The single shot must not be spent by a launch that could read no
    /// transcripts while there were sessions to correct.
    func testAnUnreadableTranscriptDirectoryDoesNotSpendTheSingleShot() throws {
        try seedInflatedSession(500)

        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("glyphline-absent-\(UUID().uuidString)", isDirectory: true)
        let reader = ClaudeCodeLogReader(directory: absent, watermarkStore: ledger, calendar: fixedGrid)

        XCTAssertFalse(try ledger.applyLocalSessionTokenRebuild(reader.readForRebuild()))
        XCTAssertEqual(try recordedTotal(), 500)
    }
}

/// Counts calls from the detached rebuild closure.
private final class RebuildRunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
