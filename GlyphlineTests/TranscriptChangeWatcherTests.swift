import XCTest
@testable import Glyphline

final class TranscriptChangeWatcherTests: XCTestCase {
    func testOnlyTranscriptsAreReportedOncePerPath() {
        let urls = TranscriptChangeWatcher.transcriptURLs(fromEventPaths: [
            "/p/a/s1.jsonl", "/p/a/s1.jsonl", "/p/a/notes.txt", "/p/a", "/p/b/s2.jsonl",
        ])
        XCTAssertEqual(urls.map(\.path), ["/p/a/s1.jsonl", "/p/b/s2.jsonl"])
    }

    /// No Claude Code on this machine is an ordinary state, not an error.
    @MainActor
    func testAMissingDirectoryStartsNothingAndDoesNotCrash() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("glyphline-absent-\(UUID().uuidString)")
        let watcher = TranscriptChangeWatcher(directory: missing)
        watcher.start { _ in XCTFail("nothing to report") }
        XCTAssertFalse(watcher.isRunning)
        watcher.stop()
    }
}
