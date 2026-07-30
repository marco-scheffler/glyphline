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
    }

    func readTail(at url: URL) throws -> TranscriptTail? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = Int64(try handle.seekToEnd())
        let start = max(0, size - Int64(Self.tailBudget))
        try handle.seek(toOffset: UInt64(start))
        guard let data = try handle.readToEnd() else { return nil }

        let decoder = JSONDecoder()
        let dates = TranscriptTimestampParser()

        // Backwards: the answer is the *last* conversational record, and walking
        // from the end stops at the first hit instead of parsing the whole tail.
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let record = try? decoder.decode(Record.self, from: Data(line)),
                  let type = record.type,
                  Self.conversational.contains(type),
                  let sessionID = record.sessionId,
                  let stamp = record.timestamp,
                  let timestamp = dates.date(from: stamp)
            else { continue }

            return TranscriptTail(
                sessionID: sessionID,
                isSidechain: record.isSidechain ?? false,
                cwd: record.cwd,
                gitBranch: record.gitBranch,
                timestamp: timestamp,
                activity: Self.activity(for: record)
            )
        }

        return nil
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
