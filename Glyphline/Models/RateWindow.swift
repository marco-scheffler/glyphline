import Foundation

/// How long a quota window spans. A subscription has several at once, which is
/// why this cannot be expressed by `BillingPeriod`'s single period.
enum RateWindowKind: String, Codable, CaseIterable, Sendable {
    case rollingFiveHours
    case weekly
    case billingCycle

    /// What a window is called where there is no room to spell it out: the menu
    /// bar panel, a few points wide, with a figure and a reset time on the same
    /// line. "5h" earns its terseness there.
    var shortName: String {
        switch self {
        case .rollingFiveHours: "5h"
        case .weekly: "Week"
        case .billingCycle: "Cycle"
        }
    }

    /// What it is called where there is room: a dashboard card, whose header
    /// already names the account, leaving the row to say only which window it
    /// is. A label that reads as a sentence fragment is what makes two stacked
    /// windows legible as two windows.
    ///
    /// Two names and not one, deliberately — a card is not a menu bar row, and
    /// forcing them together would make one of the two surfaces read badly. What
    /// they must not be is two *independent* sources, which is what they had
    /// drifted into: one word for a window kind can then be renamed without the
    /// other, and the app starts calling one thing two things by accident.
    var longName: String {
        switch self {
        case .rollingFiveHours: "5-hour"
        case .weekly: "Weekly"
        case .billingCycle: "Billing cycle"
        }
    }
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
    /// `nil` when there is no active window to reset — a real, common state, not
    /// missing data. A rolling five-hour window only starts on first use, so a
    /// freshly added subscription reports a fraction with no instant at all.
    /// Treating that as unusable threw away the most useful reading there is:
    /// nothing consumed, everything left.
    ///
    /// It means "cannot be waited out", never "unknown": a window with no
    /// instant names no moment to come back at, which is why the next-free
    /// string skips it while the light still counts it.
    var resetAt: Date?
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
        // No instant is a *state*, not a defect, so there is nothing here to
        // disbelieve. An instant that IS present still has to be in the future:
        // a reset already elapsed at the moment of observation is a reading the
        // provider cannot have meant.
        guard let resetAt else { return true }
        return resetAt > now
    }
}
