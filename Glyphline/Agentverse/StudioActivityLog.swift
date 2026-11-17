import Foundation

/// What the Studio remembers across sweeps: the tokens-per-minute wave and the
/// feed of what changed.
///
/// A pure value the coordinator records into once per successful sweep. Nothing
/// here is persisted; a fresh window starts with an empty wave.
struct StudioActivityLog: Equatable, Sendable {
    struct Sample: Equatable, Sendable { let at: Date; let tokensPerMinute: Double }
    enum Change: Equatable, Sendable { case action(AgentAction), startedWaiting, resumed }
    /// Not `Identifiable`: two changes of one session in the same second
    /// would share any id built from them, so lists key entries by position.
    struct Entry: Equatable, Sendable {
        let at: Date; let sessionID: String; let title: String; let change: Change
    }

    static let window: TimeInterval = 30 * 60
    static let entryLimit = 20
    static let gapThreshold: TimeInterval = 2 * 60

    /// Oldest first, pruned to `window` before the last record.
    private(set) var samples: [Sample] = []
    /// Newest first by `at`, at most `entryLimit`.
    private(set) var entries: [Entry] = []

    private var previousSessions: [String: AgentSession] = [:]
    private var previousTokens: [String: Int64] = [:]
    private var previousAt: Date?
    /// The last tool action each session was seen with. A thinking pause in
    /// between must not make the same edit read as new when it shows again.
    private var lastToolActions: [String: AgentAction] = [:]

    mutating func record(sessions: [AgentSession], workTokens: [String: Int64], at now: Date) {
        defer {
            previousSessions = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            lastToolActions = lastToolActions.filter { id, _ in previousSessions[id] != nil }
            for session in sessions where session.action.isToolAction {
                lastToolActions[session.id] = session.action
            }
            previousTokens = workTokens
            previousAt = now
        }
        // The first record only seeds: there is nothing to compare it with.
        guard let previousAt else { return }

        let elapsed = now.timeIntervalSince(previousAt)
        if elapsed > 0 {
            // Only growth counts. A session that parked, vanished or whose
            // counter fell back adds nothing rather than pulling the wave below zero.
            let delta = workTokens.reduce(Int64(0)) { sum, pair in
                sum + max(0, pair.value - (previousTokens[pair.key] ?? pair.value))
            }
            samples.append(Sample(at: now, tokensPerMinute: Double(delta) / elapsed * 60))
        }
        samples.removeAll { now.timeIntervalSince($0.at) > Self.window }

        for session in sessions {
            guard let change = change(from: previousSessions[session.id], to: session) else { continue }
            entries.append(Entry(
                at: session.lastActivityAt,
                sessionID: session.id,
                title: session.displayTitle,
                change: change
            ))
        }
        entries.sort { $0.at > $1.at }
        if entries.count > Self.entryLimit {
            entries.removeLast(entries.count - Self.entryLimit)
        }
    }

    /// Runs of samples split where neighbours are more than `gapThreshold`
    /// apart, so a sleep or a closed window is a break, not a plateau.
    func segments() -> [[Sample]] {
        var result: [[Sample]] = []
        for sample in samples {
            if let last = result.last?.last,
               sample.at.timeIntervalSince(last.at) <= Self.gapThreshold {
                result[result.count - 1].append(sample)
            } else {
                result.append([sample])
            }
        }
        return result
    }

    /// `AgentActivity` alone says working or waiting; the action only names
    /// what a working session moved on to. Thinking is never an entry.
    private func change(from previous: AgentSession?, to session: AgentSession) -> Change? {
        switch session.activity {
        case .waitingForYou:
            return previous?.activity == .waitingForYou ? nil : .startedWaiting
        case .working:
            if previous?.activity == .waitingForYou { return .resumed }
            guard session.action.isToolAction, session.action != lastToolActions[session.id] else { return nil }
            return .action(session.action)
        }
    }
}
