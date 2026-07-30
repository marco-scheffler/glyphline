import XCTest
@testable import Glyphline

final class ClaudeTranscriptReaderTests: XCTestCase {
    /// Every line here is shaped like a real transcript record, because the
    /// reader's whole job is telling the shapes apart.
    private func write(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func assistant(stopReason: String?, ts: String = "2026-07-30T12:00:00.000Z") -> String {
        let stop = stopReason.map { "\"stop_reason\":\"\($0)\"" } ?? "\"stop_reason\":null"
        return """
        {"type":"assistant","sessionId":"S1","isSidechain":false,"cwd":"/repo",\
        "gitBranch":"main","timestamp":"\(ts)","message":{"role":"assistant",\(stop),\
        "content":[{"type":"text","text":"hi"}]}}
        """
    }

    func testAssistantEndingItsTurnIsWaitingForYou() throws {
        let file = try write([assistant(stopReason: "end_turn")])

        let tail = try ClaudeTranscriptReader().readTail(at: file)

        XCTAssertEqual(tail?.activity, .waitingForYou)
        XCTAssertEqual(tail?.sessionID, "S1")
        XCTAssertEqual(tail?.cwd, "/repo")
        XCTAssertEqual(tail?.gitBranch, "main")
        XCTAssertEqual(tail?.isSidechain, false)
    }

    func testAssistantCallingAToolIsWorking() throws {
        let file = try write([assistant(stopReason: "tool_use")])

        XCTAssertEqual(try ClaudeTranscriptReader().readTail(at: file)?.activity, .working)
    }

    func testToolResultComingBackIsWorking() throws {
        let file = try write([
            assistant(stopReason: "tool_use"),
            """
            {"type":"user","sessionId":"S1","isSidechain":false,"cwd":"/repo",\
            "timestamp":"2026-07-30T12:00:01.000Z","toolUseResult":{"ok":true},\
            "message":{"role":"user","content":[{"type":"tool_result","content":"done"}]}}
            """,
        ])

        XCTAssertEqual(try ClaudeTranscriptReader().readTail(at: file)?.activity, .working)
    }

    /// 50 of the 182 transcripts touched within a day on the reference machine end
    /// on a record like these. Reading the last line would call an idle session busy.
    func testBookkeepingAfterTheLastTurnIsSkipped() throws {
        let file = try write([
            assistant(stopReason: "end_turn"),
            #"{"type":"last-prompt","sessionId":"S1","timestamp":"2026-07-30T12:00:02.000Z"}"#,
            #"{"type":"permission-mode","sessionId":"S1","mode":"default"}"#,
            #"{"type":"queue-operation","op":"drain"}"#,
            #"{"noType":true}"#,
        ])

        XCTAssertEqual(try ClaudeTranscriptReader().readTail(at: file)?.activity, .waitingForYou)
    }

    func testTranscriptWithNoConversationalRecordYieldsNothing() throws {
        let file = try write([#"{"type":"worktree-state","branch":"main"}"#])

        XCTAssertNil(try ClaudeTranscriptReader().readTail(at: file))
    }

    func testTrailingPartialLineIsIgnored() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")
        try (assistant(stopReason: "end_turn") + "\n" + #"{"type":"assis"#)
            .write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(try ClaudeTranscriptReader().readTail(at: file)?.activity, .waitingForYou)
    }
}
