import Foundation

/// Narrow view of the reader, so the scanner can be tested without touching real
/// transcripts and so a test can observe which files were opened at all.
protocol TranscriptTailReading: Sendable {
    func readTail(at url: URL) throws -> TranscriptTail?
}

// The reader holds nothing mutable, but Swift only accepts a checked `Sendable`
// in the type's own file, and Task 1's reader stays untouched.
extension ClaudeTranscriptReader: TranscriptTailReading, @unchecked Sendable {}

/// Sweeps `~/.claude/projects` and returns the sessions that have written
/// recently, with their subagents folded in.
///
/// The sweep is deliberately cheap. A full `stat` of all 2 972 transcripts on the
/// reference machine took 254 ms; opening them all took 0.5 s and read 1.86 GB.
/// Only files whose modification date falls inside the horizon are opened at all,
/// which on that machine was 23 files out of 2 972.
struct AgentSessionScanner {
    /// How far back a transcript may have been written and still count as on the
    /// map. Doubles as the park threshold — see `AgentverseModel`.
    static let horizon: TimeInterval = 60 * 60

    private let directory: URL
    private let reader: any TranscriptTailReading
    private let fileManager: FileManager

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        reader: any TranscriptTailReading = ClaudeTranscriptReader(),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.reader = reader
        self.fileManager = fileManager
    }

    func scan(now: Date = Date()) throws -> [AgentSession] {
        let cutoff = now.addingTimeInterval(-Self.horizon)

        var mains: [String: AgentSession] = [:]
        var sidechains: [String: (count: Int, newest: Date)] = [:]

        for url in transcriptURLs() {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            guard let modified = attributes?[.modificationDate] as? Date,
                  modified >= cutoff,
                  let tail = try reader.readTail(at: url)
            else { continue }

            if tail.isSidechain {
                let existing = sidechains[tail.sessionID]
                sidechains[tail.sessionID] = (
                    count: (existing?.count ?? 0) + 1,
                    newest: max(existing?.newest ?? .distantPast, tail.timestamp)
                )
            } else {
                // A session writes one main transcript. If two files somehow claim
                // the same id, the newer one is the truth.
                if let existing = mains[tail.sessionID], existing.lastActivityAt >= tail.timestamp {
                    continue
                }
                mains[tail.sessionID] = AgentSession(
                    id: tail.sessionID,
                    cwd: tail.cwd ?? "",
                    gitBranch: tail.gitBranch,
                    activity: tail.activity,
                    lastActivityAt: tail.timestamp
                )
            }
        }

        // A sidechain without a main transcript inside the horizon has no card to
        // sit on, and inventing one would put a subagent on the track as if it
        // were a session.
        return mains.values
            .map { session in
                var session = session
                if let side = sidechains[session.id] {
                    session.subagentCount = side.count
                    session.lastActivityAt = max(session.lastActivityAt, side.newest)
                }
                return session
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private func transcriptURLs() -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
    }
}
