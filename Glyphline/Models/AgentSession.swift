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
    /// The `ai-title` record's `aiTitle`, if the transcript carries one. This is
    /// the same string the editor extension shows, and the only field that tells
    /// two sessions in one repository apart.
    var aiTitle: String?
    /// The generated three-word name — "tidy-toasting-pelican". Always present,
    /// which is what makes it the fallback while a title is still being formed.
    var slug: String?
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
    /// What this session is actually doing, in words. See `TranscriptTail`.
    var aiTitle: String? = nil
    var slug: String? = nil

    /// The label every surface leads with.
    var displayTitle: String {
        SessionLabel.displayTitle(aiTitle: aiTitle, slug: slug, cwd: cwd)
    }

    /// The repository, now the *secondary* line: every session in one checkout
    /// shares it, so on its own it cannot tell them apart.
    var repositoryName: String { SessionLabel.repositoryName(cwd: cwd) }
}

/// How a session is named on screen, in one place, because several surfaces have
/// to agree on it.
///
/// The one character count left here is the sidebar's, and it is a count because
/// the sidebar's column is a constant width. Everything drawn into a canvas is
/// cut with `LabelFit` against the width it actually gets.
enum SessionLabel {
    /// The sidebar's column is a fixed 264 pt of proportional text.
    static let sidebarLimit = 42
    // The office plates, the datastream's lane headers and the off-the-clock
    // strip have no limit here. Each of them is a fraction of the pane, so a
    // character count in this list could only ever be right at one window size;
    // `LabelFit` cuts them to the measured width instead.

    /// The last path component, and the whole path when there is no component to
    /// take — `URL(fileURLWithPath:)` answers "/" and "." for the degenerate
    /// cases, neither of which names anything.
    static func repositoryName(cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        let component = URL(fileURLWithPath: cwd).lastPathComponent
        return component == "/" || component == "." ? cwd : component
    }

    /// Title, then slug, then repository. Never empty for a session that has a
    /// `cwd`, because the last step always has something to say.
    static func displayTitle(aiTitle: String?, slug: String?, cwd: String) -> String {
        for candidate in [aiTitle, slug, repositoryName(cwd: cwd)] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return ""
    }

    /// Clipped at the *end*: a title's distinguishing words are usually its
    /// first ones, and cutting the middle out of "PR 3 fortsetzen: …Task 6"
    /// would take exactly the part that differs from its neighbour.
    static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
