import Foundation

/// Narrow view of the reader, so the scanner can be tested without touching real
/// transcripts and so a test can observe which files were opened at all.
protocol TranscriptTailReading: Sendable {
    func readTail(at url: URL) throws -> TranscriptTail?
}

extension ClaudeTranscriptReader: TranscriptTailReading {}

/// So the coordinator can be tested without a transcript directory on disk.
protocol AgentSessionScanning: Sendable {
    func scan(now: Date) throws -> [AgentSession]
}

extension AgentSessionScanner: AgentSessionScanning {}

/// Sweeps `~/.claude/projects` and returns the sessions that wrote inside the
/// read window, with their subagents folded in.
///
/// The sweep is deliberately cheap. Walking and statting all 3 029 transcripts on
/// the reference machine took 374 ms; only the files inside `readWindow` are
/// opened at all, 732 of those 3 029, and reading their tails cost 103 ms and
/// 138 MB. What bounds that second figure is `ClaudeTranscriptReader.tailBudget`
/// per file, not transcript size — opening all 3 029 in full reads 1.86 GB.
///
/// The result is unordered. `AgentverseRules` sorts what it puts on the track,
/// and sorting here as well would only be a second answer to the same question.
struct AgentSessionScanner {
    /// How far back the sweep reads.
    ///
    /// Deliberately wider than `horizon`, and the two must never be the same
    /// number: a session parks by being *scanned* after it has gone quiet, so it
    /// has to stay in the sweep well past the moment it crosses the park
    /// threshold. One number doing both jobs drops a session out of the sweep at
    /// the exact instant it becomes park-eligible, and then nothing ever parks.
    ///
    /// Sized to `AgentverseRules.parkExpiry`: a session quiet for longer than the
    /// pit lane keeps a row could not produce a row worth keeping anyway. Spelled
    /// out rather than referenced, because the rules already reach into the
    /// scanner and a reference back would make that circular to read.
    static let readWindow: TimeInterval = 96 * 60 * 60

    /// How recently a transcript must have been written for its session to still
    /// count as on the map. The park threshold and nothing else — it is applied
    /// in `AgentverseRules.reconcile`, never here, because parking is a decision
    /// about a session the sweep already returned.
    static let horizon: TimeInterval = 60 * 60

    private let directory: URL
    private let reader: any TranscriptTailReading
    /// `FileManager` is thread-safe for the metadata calls used here, but is not
    /// marked `Sendable`; the scanner has to be, to run off the main actor.
    nonisolated(unsafe) private let fileManager: FileManager

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
        let cutoff = now.addingTimeInterval(-Self.readWindow)

        var mains: [String: AgentSession] = [:]
        var sidechains: [String: (count: Int, newest: Date)] = [:]

        for url in transcriptURLs() {
            // Every step here is optional on purpose. A transcript can be deleted
            // or rotated between the enumerator's snapshot and this open, and one
            // file racing the sweep must cost that file, not the whole sweep —
            // the caller turns a throw into an empty map and an error banner.
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                  modified >= cutoff,
                  let tail = try? reader.readTail(at: url)
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

        // A sidechain without a main transcript inside the read window has no card
        // to sit on, and inventing one would put a subagent on the track as if it
        // were a session.
        return mains.values.map { session in
            var session = session
            if let side = sidechains[session.id] {
                session.subagentCount = side.count
                session.lastActivityAt = max(session.lastActivityAt, side.newest)
            }
            return session
        }
    }

    private func transcriptURLs() -> [URL] {
        ClaudeTranscriptDirectory.transcriptURLs(
            in: directory,
            fileManager: fileManager,
            prefetching: [.contentModificationDateKey]
        )
    }
}
