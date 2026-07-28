import Foundation

/// Deterministic windows for tests and for exercising the UI before any real
/// provider route is known. Matches the `FixtureProviderAdapter` convention.
struct FixtureRateWindowSource: RateWindowSource {
    enum Behaviour: Sendable {
        case healthy
        case unavailable
    }

    var now: @Sendable () -> Date
    var behaviour: Behaviour

    init(now: @escaping @Sendable () -> Date = Date.init, behaviour: Behaviour = .healthy) {
        self.now = now
        self.behaviour = behaviour
    }

    func fetchWindows(account: Account, secret: String?) async throws -> RateWindowResult {
        let instant = now()

        switch behaviour {
        case .unavailable:
            return RateWindowResult(
                windows: [],
                dataQuality: .unavailable,
                message: "No quota source is set up for this subscription."
            )
        case .healthy:
            return RateWindowResult(
                windows: [
                    RateWindow(
                        kind: .rollingFiveHours,
                        usedFraction: 0.62,
                        resetAt: instant.addingTimeInterval(3_600),
                        observedAt: instant
                    ),
                    RateWindow(
                        kind: .weekly,
                        usedFraction: 0.31,
                        resetAt: instant.addingTimeInterval(3 * 86_400),
                        observedAt: instant
                    ),
                ],
                dataQuality: .partial,
                message: nil
            )
        }
    }
}
