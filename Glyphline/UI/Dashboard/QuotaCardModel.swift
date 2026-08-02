import Foundation

/// How a quota window reads on a card: fine, spending too fast, or nothing left.
///
/// Deliberately not `QuotaSeverity`. That enum answers "how little is left",
/// which the row list needs; a card's middle state answers "are you ahead of
/// your own pace", which is a different question with a different threshold.
enum QuotaCardState: Equatable, Sendable {
    case ok
    case warn
    case spent
}

/// One quota window as a card draws it: a bar, a marker on that bar, and the
/// sentence underneath.
///
/// The marker is the reason this type exists. "37% left" says nothing on its
/// own; "37% left where an even burn would have left you 60%" says stop. The
/// marker sits where a perfectly even burn to the reset would put you *now*.
///
/// This type states that position as the elapsed share of the window — how far a
/// an even burn would have spent you. `QuotaBar` mirrors it, because the bar it
/// draws drains rather than fills, so a bar *short* of the marker is the one
/// that will not survive to its reset.
struct QuotaCardModel: Identifiable, Equatable, Sendable {
    var kind: RateWindowKind
    /// What the provider says is consumed, clamped to 0…1. A figure outside that
    /// range is a provider defect, and a bar drawn from it would run off its
    /// track or backwards.
    var usedFraction: Double
    /// What is left, never negative for the same reason.
    var headroomFraction: Double
    var usedPercent: Int
    var headroomPercent: Int
    var usageText: String
    var headroomText: String
    /// Where an even burn to the reset would have you now, in 0…1, or `nil` for
    /// a window with no span or no reset instant to measure against — a billing
    /// cycle's length is whatever the subscription says, and guessing one would
    /// put a confident marker on the window least able to support it.
    ///
    /// Always finite and always in range: a reset instant already in the past
    /// clamps to 1 rather than overshooting, because a NaN or a 1.4 here reaches
    /// the layout as a blank or a broken card instead of an obvious error.
    var pacePosition: Double?
    /// "on track" / "empty in …", computed by `QuotaIndicator.paceText` and not
    /// recomputed here — two surfaces with two implementations of one sentence
    /// is how an app starts disagreeing with itself about when it runs out.
    var paceText: String?
    var state: QuotaCardState

    var id: RateWindowKind { kind }

    /// `nil` when the window reports no consumed fraction: there is no bar to
    /// draw and no honest state to name. An unknown usage is not "nothing used".
    static func make(for window: RateWindow, now: Date) -> QuotaCardModel? {
        guard let reported = window.usedFraction else { return nil }

        let used = min(max(reported, 0), 1)
        let headroom = 1 - used
        let pace = pacePosition(for: window, now: now)

        return QuotaCardModel(
            kind: window.kind,
            usedFraction: used,
            headroomFraction: headroom,
            usedPercent: percent(used),
            headroomPercent: percent(headroom),
            usageText: String(
                localized: "\(percent(used))% used",
                comment: "Quota card figure. The placeholder is a whole percentage."
            ),
            headroomText: String(
                localized: "\(percent(headroom))% left",
                comment: "Quota card figure. The placeholder is a whole percentage."
            ),
            pacePosition: pace,
            paceText: QuotaIndicator.paceText(for: window, now: now),
            state: state(used: used, pace: pace)
        )
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    /// Exhaustion is judged by `QuotaIndicator`'s single threshold rather than a
    /// literal here; the warning band is the marker itself, so a card warns for
    /// exactly the reason it draws the marker.
    private static func state(used: Double, pace: Double?) -> QuotaCardState {
        if QuotaIndicator.severity(forRemaining: 1 - used) == .exhausted { return .spent }
        guard let pace, used > pace else { return .ok }
        return .warn
    }

    /// Elapsed share of the window at `now`.
    ///
    /// Clamped rather than merely computed. The reset instant comes from a
    /// provider and the clock from this machine; they drift, and a late sync
    /// hands us a reset that has already passed. Unclamped that reads as 1.2 of
    /// a bar, and a zero span — should the span table ever gain one — would read
    /// as a NaN. Both reach a layout as a card that silently looks wrong.
    private static func pacePosition(for window: RateWindow, now: Date) -> Double? {
        guard let resetAt = window.resetAt,
              let span = QuotaIndicator.span(of: window.kind),
              span > 0
        else { return nil }

        let elapsed = now.timeIntervalSince(resetAt.addingTimeInterval(-span))
        let position = elapsed / span
        guard position.isFinite else { return nil }
        return min(max(position, 0), 1)
    }
}
