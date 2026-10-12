import CoreServices
import Foundation

/// Tells the attention controller which transcripts were just written.
@MainActor
protocol TranscriptChangeObserving: AnyObject {
    func start(onChange: @escaping @MainActor ([URL]) -> Void)
    func stop()
}

/// FSEvents on `~/.claude/projects`, reporting changed `.jsonl` files.
///
/// Event-driven rather than a faster sweep: a sweep stats every transcript on
/// the machine, about 0.4 s for 3 000 of them, and doing that every half minute
/// is a constant cost even while nothing happens. FSEvents costs nothing while
/// nothing is written. `sinceNow`, so a launch reports nothing that was written
/// before it — the tracker's horizon is the second guard against old sessions.
@MainActor
final class TranscriptChangeWatcher: TranscriptChangeObserving {
    private let directory: URL
    private let latency: TimeInterval
    /// `nonisolated(unsafe)` only so `deinit` can tear the stream down. Every
    /// other access is on the main actor, and `deinit` runs when nothing else
    /// holds the watcher, so there is no concurrent access to guard against.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var onChange: (@MainActor ([URL]) -> Void)?

    var isRunning: Bool { stream != nil }

    init(directory: URL = SyncCoordinator.claudeProjectsDirectory, latency: TimeInterval = 1) {
        self.directory = directory
        self.latency = latency
    }

    /// The context holds the watcher unretained, so a stream outliving it would
    /// call back into freed memory. The owner is expected to call `stop()`; this
    /// is the backstop if it does not.
    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    nonisolated static func transcriptURLs(fromEventPaths paths: [String]) -> [URL] {
        var seen = Set<String>()
        return paths.compactMap { path in
            guard path.hasSuffix(".jsonl"), seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    func start(onChange: @escaping @MainActor ([URL]) -> Void) {
        guard stream == nil,
              FileManager.default.fileExists(atPath: directory.path)
        else { return }
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let cfPaths = unsafeBitCast(paths, to: NSArray.self)
            let strings = (0..<count).compactMap { cfPaths[$0] as? String }
            let urls = TranscriptChangeWatcher.transcriptURLs(fromEventPaths: strings)
            guard !urls.isEmpty else { return }
            // Holds because the stream is scheduled on the main dispatch queue
            // below (FSEventStreamSetDispatchQueue(stream, .main)), so FSEvents
            // only ever invokes this callback on the main thread.
            MainActor.assumeIsolated {
                let watcher = Unmanaged<TranscriptChangeWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.onChange?(urls)
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        // The main queue, so the callback is already on the main actor and the
        // controller's state needs no lock.
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        onChange = nil
    }
}
