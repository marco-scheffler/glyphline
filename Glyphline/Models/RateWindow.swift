import Foundation

/// How long a quota window spans. A subscription has several at once, which is
/// why this cannot be expressed by `BillingPeriod`'s single period.
enum RateWindowKind: String, Codable, CaseIterable, Sendable {
    case rollingFiveHours
    case weekly
    case billingCycle
}

/// One observation of one window at one instant.
///
/// Observations are never aggregated and never replace one another: each is a
/// distinct measurement with its own `observedAt`.
struct RateWindow: Codable, Equatable, Sendable {
    var kind: RateWindowKind
    /// `nil` when a provider reports a reset instant but no consumed fraction.
    /// Such a window cannot contribute to a headroom decision.
    var usedFraction: Double?
    var resetAt: Date
    var observedAt: Date

    /// Rejects readings that cannot be true.
    ///
    /// If a provider silently changes its response format and the app parses
    /// nonsense that happens to decode, this is what keeps a fabricated figure
    /// out of the ledger — the alternative is that "the endpoint changed" looks
    /// exactly like "everything is free".
    func isPlausible(now: Date) -> Bool {
        if let usedFraction, !(0...1).contains(usedFraction) {
            return false
        }
        return resetAt > now
    }
}
