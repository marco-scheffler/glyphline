import XCTest
@testable import Glyphline

final class StudioActivityLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String,
                         _ activity: AgentActivity = .working,
                         action: AgentAction = .editing(file: "a.swift"),
                         at date: Date) -> AgentSession {
        AgentSession(id: id, cwd: "/repo/\(id)", gitBranch: "main",
                     activity: activity, lastActivityAt: date, action: action)
    }

    func testTheFirstRecordOnlySeeds() {
        var log = StudioActivityLog()
        log.record(sessions: [session("A", at: t0), session("B", at: t0)],
                   workTokens: ["A": 100, "B": 200], at: t0)
        XCTAssertTrue(log.samples.isEmpty)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testASampleIsTheSummedDeltaPerMinute() {
        var log = StudioActivityLog()
        let sessions = [session("A", at: t0), session("B", at: t0)]
        log.record(sessions: sessions, workTokens: ["A": 1_000, "B": 0], at: t0)
        log.record(sessions: sessions, workTokens: ["A": 4_000, "B": 2_000],
                   at: t0.addingTimeInterval(30))
        XCTAssertEqual(log.samples.count, 1)
        XCTAssertEqual(log.samples.first?.tokensPerMinute, 10_000)
    }

    /// A session that parks or vanishes, or whose counter falls back, must never
    /// pull the wave below zero.
    func testAVanishedOrShrinkingSessionAddsNothing() {
        var log = StudioActivityLog()
        log.record(sessions: [session("A", at: t0), session("B", at: t0)],
                   workTokens: ["A": 5_000, "B": 3_000], at: t0)
        log.record(sessions: [session("A", at: t0)], workTokens: ["A": 1_000],
                   at: t0.addingTimeInterval(15))
        XCTAssertEqual(log.samples.map(\.tokensPerMinute), [0])
    }

    func testOldSamplesFallOutOfTheWindow() {
        var log = StudioActivityLog()
        let sessions = [session("A", at: t0)]
        var tokens: Int64 = 0
        for step in 0...10 {
            tokens += 1_000
            log.record(sessions: sessions, workTokens: ["A": tokens],
                       at: t0.addingTimeInterval(Double(step) * 5 * 60))
        }
        let last = t0.addingTimeInterval(50 * 60)
        XCTAssertTrue(log.samples.allSatisfy { last.timeIntervalSince($0.at) <= StudioActivityLog.window })
        XCTAssertEqual(log.samples.count, 7)
    }

    /// The Mac slept, or the window was closed: no plateau drawn across the gap.
    func testALongGapSplitsTheWave() {
        var log = StudioActivityLog()
        let sessions = [session("A", at: t0)]
        let offsets: [TimeInterval] = [0, 15, 30, 15 * 60 + 30, 15 * 60 + 45]
        for (index, offset) in offsets.enumerated() {
            log.record(sessions: sessions, workTokens: ["A": Int64(index) * 1_000],
                       at: t0.addingTimeInterval(offset))
        }
        XCTAssertEqual(log.segments().count, 2)
    }

    func testAChangedToolActionIsAnEntryAtTheSessionsTime() {
        var log = StudioActivityLog()
        let changedAt = t0.addingTimeInterval(10)
        log.record(sessions: [session("A", action: .editing(file: "a.swift"), at: t0)],
                   workTokens: [:], at: t0)
        log.record(sessions: [session("A", action: .searching(pattern: "foo"), at: changedAt)],
                   workTokens: [:], at: t0.addingTimeInterval(15))
        XCTAssertEqual(log.entries.map(\.change), [.action(.searching(pattern: "foo"))])
        XCTAssertEqual(log.entries.first?.at, changedAt)
        XCTAssertEqual(log.entries.first?.sessionID, "A")
    }

    func testThinkingMakesNoEntry() {
        var log = StudioActivityLog()
        let actions: [AgentAction] = [.editing(file: "a.swift"), .thinking, .editing(file: "a.swift")]
        for (index, action) in actions.enumerated() {
            let at = t0.addingTimeInterval(Double(index) * 15)
            log.record(sessions: [session("A", action: action, at: at)], workTokens: [:], at: at)
        }
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testWaitingAndResumingAreEntries() {
        var log = StudioActivityLog()
        let states: [AgentActivity] = [.working, .waitingForYou, .working]
        for (index, activity) in states.enumerated() {
            let at = t0.addingTimeInterval(Double(index) * 15)
            log.record(sessions: [session("A", activity, at: at)], workTokens: [:], at: at)
        }
        XCTAssertEqual(log.entries.map(\.change), [.resumed, .startedWaiting])
    }

    func testTheFeedKeepsTwenty() {
        var log = StudioActivityLog()
        for index in 0...25 {
            let at = t0.addingTimeInterval(Double(index) * 15)
            log.record(sessions: [session("A", action: .editing(file: "f\(index).swift"), at: at)],
                       workTokens: [:], at: at)
        }
        XCTAssertEqual(log.entries.count, StudioActivityLog.entryLimit)
        XCTAssertEqual(log.entries.first?.change, .action(.editing(file: "f25.swift")))
        XCTAssertEqual(log.entries.last?.change, .action(.editing(file: "f6.swift")))
    }
}
