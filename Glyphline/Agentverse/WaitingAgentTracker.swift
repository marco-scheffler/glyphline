import Foundation

/// Decides which sessions have been waiting on the user long enough to say so.
///
/// Pure: fed tails, asked a question with a clock and a delay. Everything that
/// touches the filesystem, the clock or the notification centre lives in
/// `AgentAttentionController`, so every rule here is testable on its own.
struct WaitingAgentTracker: Sendable {
    private struct Phase: Sendable {
        var since: Date
        var title: String
        var repository: String
        var reported = false
    }

    private var phases: [String: Phase] = [:]

    /// A subagent ending its turn is the parent still working, so sidechains are
    /// ignored. A waiting tail with a newer timestamp is a new turn ended — the
    /// working record in between may have been coalesced away — so it starts a
    /// new phase; the same timestamp is the same phase seen again.
    mutating func record(_ tail: TranscriptTail) {
        guard !tail.isSidechain else { return }

        switch tail.activity {
        case .working:
            phases[tail.sessionID] = nil
        case .waitingForYou:
            if let existing = phases[tail.sessionID], existing.since >= tail.timestamp { return }
            let cwd = tail.cwd ?? ""
            phases[tail.sessionID] = Phase(
                since: tail.timestamp,
                title: SessionLabel.displayTitle(aiTitle: tail.aiTitle, slug: tail.slug, cwd: cwd),
                repository: SessionLabel.repositoryName(cwd: cwd)
            )
        }
    }

    /// Sessions whose wait has reached `delay` and that have not been reported in
    /// this phase, oldest first; marks them reported.
    ///
    /// A phase older than `AgentSessionScanner.horizon` is dropped unreported:
    /// past that the map no longer counts the session as on the track, and a
    /// notification about it would be about a terminal long since closed.
    mutating func due(now: Date, delay: TimeInterval) -> [WaitingAgent] {
        phases = phases.filter { now.timeIntervalSince($0.value.since) <= AgentSessionScanner.horizon }

        var due: [WaitingAgent] = []
        for (id, phase) in phases where !phase.reported && now.timeIntervalSince(phase.since) >= delay {
            phases[id]?.reported = true
            due.append(WaitingAgent(sessionID: id, title: phase.title,
                                    repository: phase.repository, waitingSince: phase.since))
        }
        return due.sorted { ($0.waitingSince, $0.sessionID) < ($1.waitingSince, $1.sessionID) }
    }
}
