import Foundation

/// Owns one sweep: scan, apply the rules, write what changed, publish the result.
///
/// The rules stay a pure function in `AgentverseRules`; this type does the parts
/// that touch the world. The sweep runs off the main actor because it stats a few
/// thousand files.
@MainActor
final class AgentverseCoordinator: ObservableObject {
    @Published private(set) var onTrack: [AgentSession] = []
    @Published private(set) var parked: [ParkedAgentSession] = []
    /// Set when the sweep could not run at all — no `~/.claude/projects`, for
    /// instance, which is an ordinary state on a machine without Claude Code.
    @Published private(set) var failureMessage: String?

    private let scanner: any AgentSessionScanning
    private let ledger: LedgerStore?
    /// What the previous sweep had on track. Without it there is no notion of
    /// "went quiet while we were watching", and every cold session on disk would
    /// arrive in the pit lane.
    private var liveSessionIDs: Set<String> = []

    init(scanner: any AgentSessionScanning = AgentSessionScanner(), ledger: LedgerStore?) {
        self.scanner = scanner
        self.ledger = ledger
    }

    func refresh(now: Date = Date()) async {
        guard let ledger else {
            failureMessage = "Ledger unavailable."
            return
        }

        let scanner = self.scanner
        let scanned: [AgentSession]
        do {
            scanned = try await Task.detached(priority: .utility) {
                try scanner.scan(now: now)
            }.value
        } catch {
            failureMessage = "Could not read the Claude Code transcripts."
            return
        }

        let existing: [ParkedAgentSession]
        do {
            existing = try ledger.fetchParkedAgents()
        } catch {
            failureMessage = "Could not read the parked sessions."
            return
        }

        let snapshot = AgentverseRules.reconcile(
            scanned: scanned,
            parked: existing,
            liveSessionIDs: liveSessionIDs,
            now: now
        )

        do {
            // Order is load-bearing: an id can in a pathological case be both
            // newly parked and expired, and the delete has to be the one that wins.
            for row in snapshot.newlyParked {
                try ledger.saveParkedAgent(row)
            }
            // Expiry deletes row by row, exactly like a return from the pit lane
            // does. The rules already named the ids past the deadline while
            // working out what stays parked, so a second, date-ranged delete
            // would be a second place holding the same rule.
            for id in snapshot.unparked + snapshot.expired {
                try ledger.deleteParkedAgent(sessionID: id)
            }
        } catch {
            failureMessage = "Could not update the parked sessions."
            return
        }

        onTrack = snapshot.onTrack
        parked = snapshot.parked
        liveSessionIDs = Set(snapshot.onTrack.map(\.id))
        failureMessage = nil
    }

    /// Throwing a session out of the pit lane. It comes back on its own if it
    /// starts writing again — see `AgentverseRules`.
    func dismiss(sessionID: String) {
        parked.removeAll { $0.sessionID == sessionID }
        try? ledger?.deleteParkedAgent(sessionID: sessionID)
    }
}
