import Foundation

/// What a session is doing, read from the last turn in its transcript.
///
/// Two states, because two is what the transcript can honestly support. "Idle" is
/// not among them: a session that stopped writing looks identical whether it is
/// waiting for a reply or whether the terminal was closed hours ago, and the
/// 60-minute rule — not this enum — is what separates those.
enum AgentActivity: String, Codable, Equatable, Sendable {
    /// The assistant ended its turn and nothing has happened since.
    case waitingForYou
    /// Mid-turn: a tool call is out, or a result just came back.
    case working
}

/// The last conversational record of one transcript file.
struct TranscriptTail: Equatable, Sendable {
    var sessionID: String
    /// True for a subagent transcript. Its `sessionID` is the parent's.
    var isSidechain: Bool
    var cwd: String?
    var gitBranch: String?
    var timestamp: Date
    var activity: AgentActivity
}

/// One main session as the map shows it, with its subagents folded in.
struct AgentSession: Identifiable, Equatable, Sendable {
    /// The Claude Code `sessionId`.
    let id: String
    var cwd: String
    var gitBranch: String?
    var activity: AgentActivity
    var lastActivityAt: Date
    /// Subagents attributed to this session. They get a number on the car, not
    /// cars of their own: the reference machine had 130 of them against 32 main
    /// sessions in a day.
    var subagentCount: Int = 0
}
