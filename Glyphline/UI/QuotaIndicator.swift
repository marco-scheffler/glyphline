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

    /// The soonest reset an account can actually be waited out for: fresh
    /// enough to still be believed — the same bound `decidableFraction`
    /// applies, so the two functions cannot disagree about the same data — and
    /// still in the future, because an elapsed `resetAt` names a moment that
    /// has already come and gone.
    private static func soonestUsefulReset(
        _ state: QuotaAccountState,
        now: Date,
        freshness: TimeInterval
    ) -> Date? {
        state.windows
            .filter { now.timeIntervalSince($0.observedAt) <= freshness && $0.resetAt > now }
            .map(\.resetAt)
            .min()
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
                guard let earliest = soonestUsefulReset(state, now: now, freshness: freshness) else {
                    return nil
                }
                return (state.displayName, earliest)
            }
            .min { $0.1 < $1.1 }

        guard let soonest else { return nil }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(soonest.0) at \(formatter.string(from: soonest.1))"
    }

    /// The app's own glyph, and what the menu bar shows when the light carries no
    /// information.
    static let appSymbolName = "chart.line.uptrend.xyaxis"

    /// Three symbols that differ in fill as well as in name, so the light is
    /// legible in a monochrome menu bar rather than only in code.
    ///
    /// Grey is the app's own glyph rather than a neutral dot. The access-route
    /// spike found no provider route to short-term rate windows, so grey is not a
    /// rare degraded state — it is what every user sees until a real source
    /// ships. The state that carries no information must not also cost the app its
    /// identity in the menu bar; green and red are the deviation from normal.
    static func symbolName(for state: QuotaLightState) -> String {
        switch state {
        case .green: "circle.fill"
        case .red: "circle.slash.fill"
        case .grey: appSymbolName
        }
    }

    /// What VoiceOver reads for the menu bar item. The symbol alone conveys the
    /// state visually; this is the same information in words.
    static func accessibilityLabel(for state: QuotaLightState) -> String {
        switch state {
        case .green: "Glyphline — quota available"
        case .red: "Glyphline — quota exhausted"
        case .grey: "Glyphline — quota unknown"
        }
    }

    /// One window as a menu row. A missing fraction says so rather than
    /// rendering as 0%, which would read as "untouched".
    static func rowText(for window: RateWindow, now: Date) -> String {
        let label: String
        switch window.kind {
        case .rollingFiveHours: label = "5h"
        case .weekly: label = "Week"
        case .billingCycle: label = "Cycle"
        }

        // A local, not a `static let`: `DateFormatter` is not `Sendable`.
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let reset = formatter.string(from: window.resetAt)

        guard let fraction = window.usedFraction else {
            return "\(label) — usage unknown, resets \(reset)"
        }
        return "\(label) \(Int((fraction * 100).rounded()))% — resets \(reset)"
    }
}
