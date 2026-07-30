import Foundation

/// Finding the transcripts under a `~/.claude/projects`-shaped directory.
///
/// Shared by the two readers that walk it, so what counts as a transcript — and
/// the fact that the walk is recursive, because every project slug is its own
/// subdirectory — is decided in one place.
enum ClaudeTranscriptDirectory {
    /// - Parameter keys: resource values to fetch alongside the directory read.
    ///   The enumerator has to touch each entry anyway, so a caller that names
    ///   what it needs here gets it for free; asking for nothing and then
    ///   statting the file costs a second trip to the filesystem per transcript.
    ///
    /// Sorted by path so two sweeps of an unchanged directory do the same work in
    /// the same order — enumeration order is otherwise the filesystem's business.
    static func transcriptURLs(
        in directory: URL,
        fileManager: FileManager,
        prefetching keys: [URLResourceKey]
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.path < $1.path }
    }
}
