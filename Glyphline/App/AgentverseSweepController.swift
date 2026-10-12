import Foundation

/// Sweeps the Agentverse on a slow cadence, whether or not a window shows it.
///
/// App-level rather than attached to a view, for the reason
/// `LocalScanScheduleController` is. The only sweeps used to come from the
/// dashboard's `task` and the map window's loop, and a session parks only when
/// the sweep before saw it on track — that is what `AgentverseRules.reconcile`
/// means by "while the app was watching". In the default menu bar mode neither
/// window may open for hours, so a session that started and went quiet in that
/// time was never seen on track and never reached the pit lane: it simply
/// disappeared from the map.
///
/// The map window keeps its own fifteen-second loop; that one is for the
/// picture. This one only has to make sure no session goes unseen.
@MainActor
final class AgentverseSweepController {
    /// Fifteen minutes. A session stays on track for `AgentSessionScanner.horizon`
    /// — an hour — after its last write, so any interval below that sees every
    /// session at least once before it is due to park. At about 374 ms a sweep
    /// this is a 0.04 % duty cycle, where the window's fifteen seconds would be
    /// 2.5 % for the whole life of the process.
    static let interval: TimeInterval = 15 * 60

    private var loop: Task<Void, Never>?

    /// - Parameter sweep: one pass, awaited before the next sleep so a slow sweep
    ///   delays the cadence rather than overlapping with itself.
    /// - Parameter sleepForSeconds: injected so a test can run the loop without
    ///   waiting fifteen minutes.
    init(
        sweep: @escaping @MainActor () async -> Void,
        sleepForSeconds: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        // Sweep before the first sleep: the launch sweep is what gives the next
        // one a previous sweep to compare against.
        loop = Task { @MainActor in
            while !Task.isCancelled {
                await sweep()
                do {
                    try await sleepForSeconds(Self.interval)
                } catch {
                    return
                }
            }
        }
    }

    deinit {
        loop?.cancel()
    }
}
