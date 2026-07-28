import Foundation

enum QuotaLightState: Equatable, Sendable {
    case green
    case red
    case grey
}

struct QuotaAccountState: Equatable, Sendable {
    var accountID: UUID
    var displayName: String
    var windows: [RateWindow]
    var message: String?
}

enum QuotaIndicator {
    /// A window can only decide headroom when it is fresh *and* carries a
    /// fraction. A reset instant without a fraction is worth displaying but
    /// tells us nothing about capacity.
    private static func decidableFraction(
        _ window: RateWindow,
        now: Date,
        freshness: TimeInterval
    ) -> Double? {
        guard now.timeIntervalSince(window.observedAt) <= freshness else { return nil }
        return window.usedFraction
    }

    /// `nil` means "we do not know" — no fresh window carried a fraction. That
    /// is deliberately distinct from `false` (known to be exhausted), because
    /// only known exhaustion may darken the light.
    private static func hasHeadroom(
        _ state: QuotaAccountState,
        now: Date,
        freshness: TimeInterval
    ) -> Bool? {
        let fractions = state.windows.compactMap {
            decidableFraction($0, now: now, freshness: freshness)
        }
        guard !fractions.isEmpty else { return nil }
        return fractions.allSatisfy { $0 < 1.0 }
    }

    /// Green when at least one account with fresh data has headroom. Red only
    /// when every account is known and every one is exhausted. Grey otherwise —
    /// two exhausted subscriptions plus one that failed to answer is not red,
    /// because the silent one might have capacity.
    static func light(
        for states: [QuotaAccountState],
        now: Date,
        freshness: TimeInterval
    ) -> QuotaLightState {
        guard !states.isEmpty else { return .grey }

        let verdicts = states.map { hasHeadroom($0, now: now, freshness: freshness) }

        if verdicts.contains(where: { $0 == true }) { return .green }
        // `allSatisfy`, not `contains`: a single unknown account (verdict `nil`)
        // is enough to withhold red, however many neighbours are exhausted.
        if verdicts.allSatisfy({ $0 == false }) { return .red }
        return .grey
    }

    /// The account to reach for next, as a display string.
    static func nextFree(
        for states: [QuotaAccountState],
        now: Date,
        freshness: TimeInterval
    ) -> String? {
        let available = states.first { hasHeadroom($0, now: now, freshness: freshness) == true }
        if let available {
            return "\(available.displayName) — now"
        }

        let soonest = states
            .filter { hasHeadroom($0, now: now, freshness: freshness) == false }
            .compactMap { state -> (String, Date)? in
                guard let earliest = state.windows.map(\.resetAt).min() else { return nil }
                return (state.displayName, earliest)
            }
            .min { $0.1 < $1.1 }

        guard let soonest else { return nil }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(soonest.0) at \(formatter.string(from: soonest.1))"
    }
}
