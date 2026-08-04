import Foundation

/// The one place that lets something read the transcripts and write the local
/// history, and the reason the one-time rebuild and the ordinary scan cannot
/// collide.
///
/// They otherwise would. The rebuild starts in `GlyphlineApp.init`; the ordinary
/// launch scan starts from `DashboardView`'s `task`, and the dashboard opens at
/// launch on a fresh install and in every mode but `menuBarOnly`. Both walk the
/// same thousands of files for the same twenty seconds, and
/// `addLocalTokenUsage` is additive — so a scan that reads before the rebuild
/// commits and writes after it would add its own totals on top of the day the
/// rebuild had just replaced, and re-inflate exactly what this feature exists to
/// fix, on exactly the installations it exists for.
///
/// The mechanism is state, not timing. `rebuildIsOutstanding` is set when the
/// gate is built — synchronously, in `GlyphlineApp.init`, from the durable
/// marker — so it is already true before any window exists to start a scan.
/// `runScan` reads that flag inside the actor and, while it is true, suspends on
/// a continuation this actor holds; it cannot reach `work()` at all. The flag is
/// cleared, and the waiters resumed, only in `runRebuild`'s `defer`, after the
/// rebuild's transaction has committed or thrown. There is no interleaving to
/// lose: a scan either never started, or started after the rebuild was over —
/// and after it is over the rebuild's watermarks sit at the end of every file, so
/// the scan finds nothing to add.
///
/// A failed rebuild releases the waiters just the same. Nothing of it landed, the
/// marker is unset, and the ordinary scan is free to behave as it always did.
actor LocalHistoryWriteGate {
    private var rebuildIsOutstanding: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// - Parameter rebuildIsOutstanding: whether a rebuild is going to run this
    ///   launch. Passed in at construction rather than discovered later, because a
    ///   flag that is only set once the rebuild happens to get scheduled is a
    ///   race, not a mechanism.
    init(rebuildIsOutstanding: Bool) {
        self.rebuildIsOutstanding = rebuildIsOutstanding
    }

    /// Runs the one-time rebuild, alone. Returns what the work reported, or
    /// `false` if it threw.
    ///
    /// The work runs detached at utility priority: it is twenty seconds of file
    /// reading and must not sit on a cooperative thread or on the main actor.
    /// Suspending here is safe — every scan is behind the flag until the `defer`.
    func runRebuild(_ work: @escaping @Sendable () throws -> Bool) async -> Bool {
        defer { releaseScans() }

        return await Task.detached(priority: .utility) { () -> Bool in
            do {
                return try work()
            } catch {
                return false
            }
        }.value
    }

    /// Opens the gate without running anything, for the object responsible for
    /// the rebuild to call on every path where it declines to run one.
    ///
    /// Without it the gate's safety depends on a coincidence: the flag is
    /// computed from the same markers the rebuild controller guards on, so today
    /// an armed gate always gets a rebuild. Nothing enforced that. A gate armed
    /// with nobody left to open it suspends every `runScan` forever — local usage
    /// silently never updates again, with no bound and no error. Making the
    /// decliner release it turns that from a coincidence into the shape of the
    /// code. It cannot weaken the exclusion: a rebuild that *is* running still
    /// holds the gate until its own `defer`.
    func declineRebuild() {
        releaseScans()
    }

    /// Runs an ordinary scan, never before an outstanding rebuild has finished.
    /// Reports whether the work completed without throwing.
    func runScan(_ work: @escaping @Sendable () throws -> Void) async -> Bool {
        while rebuildIsOutstanding {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
            }
        }

        return await Task.detached(priority: .utility) { () -> Bool in
            do {
                try work()
                return true
            } catch {
                return false
            }
        }.value
    }

    private func releaseScans() {
        rebuildIsOutstanding = false
        let resumable = waiting
        waiting = []
        for continuation in resumable {
            continuation.resume()
        }
    }
}
