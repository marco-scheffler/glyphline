import GRDB
import XCTest
@testable import Glyphline

final class AgentSessionScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func transcript(
        slug: String,
        name: String,
        sessionID: String,
        isSidechain: Bool,
        cwd: String,
        branch: String? = "main",
        stopReason: String = "end_turn",
        aiTitle: String? = nil,
        at date: Date
    ) throws -> URL {
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).jsonl")
        let stamp = ISO8601DateFormatter().string(from: date)
        let branchField = branch.map { "\"gitBranch\":\"\($0)\"," } ?? ""
        let line = """
        {"type":"assistant","sessionId":"\(sessionID)","isSidechain":\(isSidechain),\
        "cwd":"\(cwd)",\(branchField)"timestamp":"\(stamp)",\
        "message":{"role":"assistant","stop_reason":"\(stopReason)","content":[]}}
        """
        let title = aiTitle.map {
            "{\"type\":\"ai-title\",\"aiTitle\":\"\($0)\",\"sessionId\":\"\(sessionID)\"}\n"
        } ?? ""
        try (title + line + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        return file
    }

    /// The title has to survive the whole path from the file to the model, and
    /// two sessions sharing a `cwd` — the normal case — have to come out apart.
    func testTheScannerCarriesEachSessionsOwnTitle() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try transcript(slug: "-repo-a", name: "S1", sessionID: "S1", isSidechain: false,
                       cwd: "/repo/a", aiTitle: "Issue 558 auf Umsetzbarkeit prüfen",
                       at: now.addingTimeInterval(-30))
        try transcript(slug: "-repo-a", name: "S2", sessionID: "S2", isSidechain: false,
                       cwd: "/repo/a", aiTitle: "PR 3 fortsetzen",
                       at: now.addingTimeInterval(-20))

        let byID = Dictionary(uniqueKeysWithValues:
            try AgentSessionScanner(directory: root).scan(now: now).map { ($0.id, $0) })

        XCTAssertEqual(byID["S1"]?.aiTitle, "Issue 558 auf Umsetzbarkeit prüfen")
        XCTAssertEqual(byID["S2"]?.aiTitle, "PR 3 fortsetzen")
        XCTAssertNotEqual(byID["S1"]?.displayTitle, byID["S2"]?.displayTitle)
    }

    /// Subagent transcripts carry the parent's sessionId but live under a
    /// different project slug — 130 of 130 matched on the reference machine — so
    /// grouping keys on the id and never on the directory.
    func testSubagentsFoldIntoTheirParentBySessionID() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try transcript(slug: "-repo-a", name: "S1", sessionID: "S1", isSidechain: false,
                       cwd: "/repo/a", at: now.addingTimeInterval(-30))
        try transcript(slug: "-repo-b", name: "agent-1", sessionID: "S1", isSidechain: true,
                       cwd: "/repo/b", at: now.addingTimeInterval(-20))
        try transcript(slug: "-repo-c", name: "agent-2", sessionID: "S1", isSidechain: true,
                       cwd: "/repo/c", at: now.addingTimeInterval(-10))

        let sessions = try AgentSessionScanner(directory: root).scan(now: now)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "S1")
        XCTAssertEqual(sessions[0].cwd, "/repo/a", "the main transcript owns the identity")
        XCTAssertEqual(sessions[0].subagentCount, 2)
    }

    /// A subagent writing after its parent still moves the session's clock: the
    /// session as a whole is doing something.
    func testTheNewestWriteOfEitherKindSetsTheClock() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try transcript(slug: "-repo-a", name: "S1", sessionID: "S1", isSidechain: false,
                       cwd: "/repo/a", at: now.addingTimeInterval(-600))
        try transcript(slug: "-repo-a", name: "agent-1", sessionID: "S1", isSidechain: true,
                       cwd: "/repo/a", stopReason: "tool_use", at: now.addingTimeInterval(-5))

        let sessions = try AgentSessionScanner(directory: root).scan(now: now)

        XCTAssertEqual(sessions[0].lastActivityAt, now.addingTimeInterval(-5))
    }

    func testASidechainWithNoMainTranscriptIsDropped() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try transcript(slug: "-repo-b", name: "agent-1", sessionID: "ORPHAN", isSidechain: true,
                       cwd: "/repo/b", at: now.addingTimeInterval(-10))

        XCTAssertTrue(try AgentSessionScanner(directory: root).scan(now: now).isEmpty)
    }

    /// 3 029 transcripts sat on the reference machine against 732 inside the read
    /// window. Reading all of them on every sweep is the difference between a
    /// stat and a gigabyte.
    func testTranscriptsOlderThanTheReadWindowAreNeverOpened() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try transcript(slug: "-repo-old", name: "OLD", sessionID: "OLD",
                                 isSidechain: false, cwd: "/repo/old",
                                 at: now.addingTimeInterval(-AgentSessionScanner.readWindow - 60))
        try transcript(slug: "-repo-new", name: "NEW", sessionID: "NEW", isSidechain: false,
                       cwd: "/repo/new", at: now.addingTimeInterval(-60))

        let counting = CountingReader()
        let sessions = try AgentSessionScanner(directory: root, reader: counting).scan(now: now)

        XCTAssertEqual(sessions.map(\.id), ["NEW"])
        XCTAssertFalse(counting.opened.contains(old), "an old transcript must not be read")
    }

    /// The regression a stubbed scanner cannot catch. Parking needs the sweep to
    /// keep returning a session *after* it crossed the park threshold; when the
    /// read window and that threshold were one constant, the session left the
    /// sweep at the instant it became park-eligible and nothing ever parked.
    ///
    /// Real scanner, real transcript on disk, real ledger — only the clock moves.
    @MainActor
    func testASessionGoingQuietOnDiskParksAndIsPersisted() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try transcript(slug: "-repo-a", name: "S1", sessionID: "S1", isSidechain: false,
                       cwd: "/repo/a", at: now.addingTimeInterval(-60))

        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)
        let coordinator = AgentverseCoordinator(
            scanner: AgentSessionScanner(directory: root),
            ledger: ledger
        )

        await coordinator.refresh(now: now)
        XCTAssertEqual(coordinator.onTrack.map(\.id), ["S1"])

        // Nothing writes to the transcript again; the clock alone carries it past
        // the park threshold.
        await coordinator.refresh(now: now.addingTimeInterval(AgentSessionScanner.horizon + 600))

        XCTAssertTrue(coordinator.onTrack.isEmpty)
        XCTAssertEqual(coordinator.parked.map(\.sessionID), ["S1"])
        XCTAssertEqual(try ledger.fetchParkedAgents().map(\.sessionID), ["S1"])
    }

    /// Day one. The read window deliberately hands the rules sessions that are
    /// already cold, so the promise that a first launch offers nothing to throw
    /// away now rests entirely on `liveSessionIDs` starting empty.
    func testASessionColdSinceBeforeLaunchIsNeitherOnTrackNorParked() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try transcript(slug: "-repo-cold", name: "COLD", sessionID: "COLD", isSidechain: false,
                       cwd: "/repo/cold", at: now.addingTimeInterval(-8 * 3600))

        let scanned = try AgentSessionScanner(directory: root).scan(now: now)
        XCTAssertEqual(scanned.map(\.id), ["COLD"], "inside the read window, so still swept")

        let out = AgentverseRules.reconcile(scanned: scanned, parked: [], now: now)

        XCTAssertTrue(out.onTrack.isEmpty)
        XCTAssertTrue(out.newlyParked.isEmpty, "never seen live means never parked")
        XCTAssertTrue(out.parked.isEmpty)
    }

    private final class CountingReader: TranscriptTailReading, @unchecked Sendable {
        var opened: [URL] = []
        private let inner = ClaudeTranscriptReader()

        func readTail(at url: URL) throws -> TranscriptTail? {
            opened.append(url)
            return try inner.readTail(at: url)
        }
    }
}
