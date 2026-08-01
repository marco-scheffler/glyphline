import Foundation

/// Reads the tail of one Claude Code transcript and works out what that session
/// is doing.
///
/// Only the tail: a transcript can run to hundreds of megabytes, and the answer
/// is always within the last few records. The budget is generous enough to step
/// back over the bookkeeping that usually follows the final turn.
struct ClaudeTranscriptReader: Sendable {
    /// How much of the end of the file to consider. Measured against the
    /// reference machine, the last conversational record sat at most nine lines
    /// from the end; 256 KB covers that with room for very long tool results.
    static let tailBudget: Int = 256 * 1024

    /// Record types that carry a turn. Everything else — `last-prompt`,
    /// `permission-mode`, `queue-operation`, `worktree-state`, `pr-link`,
    /// `attachment`, `system`, and records with no `type` at all — is
    /// bookkeeping and says nothing about whose turn it is.
    private static let conversational: Set<String> = ["assistant", "user"]

    private struct Record: Decodable {
        struct Message: Decodable {
            var stopReason: String?

            enum CodingKeys: String, CodingKey {
                case stopReason = "stop_reason"
            }
        }

        var type: String?
        var sessionId: String?
        var isSidechain: Bool?
        var cwd: String?
        var gitBranch: String?
        var timestamp: String?
        var message: Message?
        var aiTitle: String?
        var slug: String?
    }

    /// Byte markers used to skip lines that cannot carry what is still missing.
    /// Without them the reader would have to JSON-decode every line of the tail
    /// instead of stopping at the last conversational record, and the sweep opens
    /// hundreds of files.
    private static let titleMarker = Array(#""ai-title""#.utf8)
    private static let slugMarker = Array(#""slug""#.utf8)

    func readTail(at url: URL) throws -> TranscriptTail? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = Int64(try handle.seekToEnd())
        let start = max(0, size - Int64(Self.tailBudget))
        try handle.seek(toOffset: UInt64(start))
        guard let data = try handle.readToEnd() else { return nil }

        let decoder = JSONDecoder()
        let dates = TranscriptTimestampParser()

        // Backwards, because every answer here is the *last* one written: the
        // last conversational record says what the session is doing, and the last
        // `ai-title` record is the current title — a session's title is refined
        // as it runs, and earlier ones are stale. Walking from the end therefore
        // means "first hit wins" for all three.
        //
        // `ai-title` is its own record type and can sit anywhere in the file, so
        // it cannot be read off the conversational record and the walk cannot
        // stop there. It stops when all three are in hand, and otherwise runs out
        // the tail.
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        var found: Record?
        var timestamp: Date?
        var aiTitle: String?
        var slug: String?

        for line in lines.reversed() {
            if found != nil {
                // Past the conversational record only a title or a slug is still
                // worth the cost of a decode.
                let mayHaveTitle = aiTitle == nil && line.firstRange(of: Self.titleMarker) != nil
                let mayHaveSlug = slug == nil && line.firstRange(of: Self.slugMarker) != nil
                if !mayHaveTitle && !mayHaveSlug { continue }
            }
            guard let record = try? decoder.decode(Record.self, from: Data(line)) else { continue }

            if aiTitle == nil, record.type == "ai-title",
               let title = record.aiTitle, !title.isEmpty {
                aiTitle = title
            }
            if slug == nil, let value = record.slug, !value.isEmpty {
                slug = value
            }
            if found == nil,
               let type = record.type,
               Self.conversational.contains(type),
               record.sessionId != nil,
               let stamp = record.timestamp,
               let date = dates.date(from: stamp) {
                found = record
                timestamp = date
            }
            if found != nil && aiTitle != nil && slug != nil { break }
        }

        guard let record = found, let sessionID = record.sessionId, let timestamp else {
            return nil
        }

        return TranscriptTail(
            sessionID: sessionID,
            isSidechain: record.isSidechain ?? false,
            cwd: record.cwd,
            gitBranch: record.gitBranch,
            timestamp: timestamp,
            activity: Self.activity(for: record),
            aiTitle: aiTitle,
            slug: slug
        )
    }

    /// The one judgement in this file.
    ///
    /// An assistant record that ended its turn — `end_turn`, and equally
    /// `max_tokens` or `stop_sequence` — is the session handing back. Anything
    /// else is mid-turn: `tool_use` means a call is out, and a `user` record is
    /// either a tool result coming back or a prompt just typed, both of which
    /// mean the session is about to work rather than waiting.
    private static func activity(for record: Record) -> AgentActivity {
        guard record.type == "assistant",
              let stop = record.message?.stopReason,
              stop != "tool_use"
        else { return .working }
        return .waitingForYou
    }
}
