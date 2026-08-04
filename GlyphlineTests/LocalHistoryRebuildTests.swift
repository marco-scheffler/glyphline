import GRDB
import XCTest
@testable import Glyphline

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

    private func runRebuild() throws {
        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
        try ledger.applyLocalHistoryRebuild(reader.readForRebuild())
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

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
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

    // MARK: - The marker

    private func makeSettings() -> AppSettingsStore {
        let defaults = UserDefaults(suiteName: "glyphline-rebuild-\(UUID().uuidString)")!
        return AppSettingsStore(defaults: defaults)
    }

    func testTheRebuildRunsOnceAndMarksItself() async {
        let settings = makeSettings()
        let runs = RebuildRunCounter()

        let first = LocalHistoryRebuildController(settings: settings) { runs.increment() }
        await first.task?.value

        XCTAssertEqual(runs.value, 1)
        XCTAssertTrue(settings.hasRebuiltLocalHistory)

        let second = LocalHistoryRebuildController(settings: settings) { runs.increment() }
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

        let controller = LocalHistoryRebuildController(settings: settings) {
            let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
            try ledger.applyLocalHistoryRebuild(reader.readForRebuild())
        }
        await controller.task?.value

        XCTAssertTrue(settings.hasRebuiltLocalHistory)
    }

    /// A failed rebuild leaves the marker unset, so the next launch tries again —
    /// the transaction means nothing of it landed.
    func testAFailedRebuildIsNotMarkedDone() async {
        let settings = makeSettings()

        struct Boom: Error {}
        let controller = LocalHistoryRebuildController(settings: settings) { throw Boom() }
        await controller.task?.value

        XCTAssertFalse(settings.hasRebuiltLocalHistory)
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
