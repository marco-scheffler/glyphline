import Foundation

/// What one sweep concluded: who is on the track, who is in the pit lane, and
/// which ledger rows have to change as a result.
struct AgentverseSnapshot: Equatable, Sendable {
    var onTrack: [AgentSession] = []
    var parked: [ParkedAgentSession] = []
    /// To be written to the ledger.
    var newlyParked: [ParkedAgentSession] = []
    /// Rows to delete: these sessions came back to life.
    var unparked: [String] = []
    /// Rows to delete: past the expiry.
    var expired: [String] = []
}

/// The entry, park, return and expiry rules, as one pure function.
///
/// Pure on purpose: this is the logic that decides whether the map is usable on
/// day one, and it is far easier to be sure of when it can be asked a question
/// without a database, a clock or a filesystem in the way.
enum AgentverseRules {
    /// How long a parked session is kept before it goes on its own. At the 17-26
    /// new sessions a day the reference machine produced, clearing by hand alone
    /// turns the pit lane into a backlog within the week.
    static let parkExpiry: TimeInterval = 96 * 60 * 60

    /// - Parameter liveSessionIDs: what the previous sweep had on track. A session
    ///   parks only if it was there — this is what "while the app is watching"
    ///   means, and it is what keeps the 320 sessions already on disk from
    ///   arriving in the pit lane at first launch.
    static func reconcile(
        scanned: [AgentSession],
        parked existingParked: [ParkedAgentSession],
        liveSessionIDs: Set<String> = [],
        now: Date = Date()
    ) -> AgentverseSnapshot {
        var snapshot = AgentverseSnapshot()
        let cutoff = now.addingTimeInterval(-AgentSessionScanner.horizon)
        let expiryCutoff = now.addingTimeInterval(-parkExpiry)

        var stillParked: [String: ParkedAgentSession] = [:]
        for row in existingParked {
            if row.parkedAt < expiryCutoff {
                snapshot.expired.append(row.sessionID)
            } else {
                stillParked[row.sessionID] = row
            }
        }

        for session in scanned {
            if session.lastActivityAt >= cutoff {
                snapshot.onTrack.append(session)
                // Back from the pit lane. Deleting the row rather than marking it
                // is what makes the return free of any second mechanism.
                if stillParked.removeValue(forKey: session.id) != nil {
                    snapshot.unparked.append(session.id)
                }
            } else if liveSessionIDs.contains(session.id), stillParked[session.id] == nil {
                let row = ParkedAgentSession(
                    sessionID: session.id,
                    cwd: session.cwd,
                    gitBranch: session.gitBranch,
                    subagentCount: session.subagentCount,
                    lastActivityAt: session.lastActivityAt,
                    parkedAt: now
                )
                snapshot.newlyParked.append(row)
                stillParked[session.id] = row
            }
        }

        snapshot.onTrack.sort { $0.lastActivityAt > $1.lastActivityAt }
        snapshot.parked = stillParked.values.sorted { $0.parkedAt > $1.parkedAt }
        return snapshot
    }
}
