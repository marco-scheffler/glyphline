import Foundation

enum QuotaLightState: Equatable, Sendable {
    case green
    case red
    case grey
}

/// Locale and time zone the quota strings are rendered in.
///
/// Injectable for one reason: a test that builds the same `DateFormatter` as the
/// implementation asserts only that the implementation equals itself. Pinning
/// these lets a test state the expected string outright — which is how the
/// time-of-day defect survived a green suite the first time.
struct QuotaFormatting: Sendable {
    var locale: Locale
    var timeZone: TimeZone

    static let current = QuotaFormatting(
        locale: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent
    )
}

/// One window together with the instant a fetch last confirmed it.
///
/// The two dates are different questions and were conflated once already.
/// `window.observedAt` is when the value was **first** seen: the store drops an
/// unchanged repeat, so it deliberately does not advance while a provider keeps
/// reporting the same figure. `confirmedAt` is when a fetch last said "this is
/// still the value", which is the only date freshness may be measured from — a
/// 5-hour window sitting at a fixed reset with a stable fraction is exactly what
/// an idle user has, and judging it by `observedAt` turned that into "unknown"
/// two poll intervals after the last change.
struct QuotaWindowState: Equatable, Sendable {
    var window: RateWindow
    /// `nil` when no fetch has confirmed this window in this process's lifetime —
    /// the row was read back from a previous run. `observedAt` then stands in as
    /// the best available lower bound on when the value was known to be current.
    var confirmedAt: Date?

    init(window: RateWindow, confirmedAt: Date? = nil) {
        self.window = window
        self.confirmedAt = confirmedAt
    }

    /// The single instant every freshness decision is taken against.
    var believableSince: Date {
        guard let confirmedAt else { return window.observedAt }
        return max(confirmedAt, window.observedAt)
    }
}

struct QuotaAccountState: Equatable, Sendable {
    var accountID: UUID
    var displayName: String
    var windows: [QuotaWindowState]
    var message: String?
}

enum QuotaIndicator {
    /// The one freshness predicate. The light, the next-free string and the
    /// rendered rows all reach it — a rule applied at two of the three sites and
    /// forgotten at the third is the mistake this feature kept making.
    static func isFresh(
        _ state: QuotaWindowState,
        now: Date,
        freshness: TimeInterval
    ) -> Bool {
        now.timeIntervalSince(state.believableSince) <= freshness
    }

    /// A window can only decide headroom when it is fresh *and* carries a
    /// fraction. A reset instant without a fraction is worth displaying but
    /// tells us nothing about capacity.
    private static func decidableFraction(
        _ state: QuotaWindowState,
        now: Date,
        freshness: TimeInterval
    ) -> Double? {
        guard isFresh(state, now: now, freshness: freshness) else { return nil }
        return state.window.usedFraction
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
            .filter { isFresh($0, now: now, freshness: freshness) && $0.window.resetAt > now }
            .map(\.window.resetAt)
            .min()
    }

    /// The account to reach for next, as a display string.
    static func nextFree(
        for states: [QuotaAccountState],
        now: Date,
        freshness: TimeInterval,
        formatting: QuotaFormatting = .current
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

        // "Name — when", the same shape as the "— now" branch above. Not
        // "Name at <instant>": once the instant can carry a date, that reads
        // "Max #1 at Jul 31, 2026 at 2:00 PM".
        return "\(soonest.0) — \(instantText(soonest.1, now: now, formatting: formatting))"
    }

    /// An instant as the user reads it: the time alone when it falls on today,
    /// date-bearing otherwise.
    ///
    /// Time alone was right for `.rollingFiveHours` and wrong for everything
    /// else. A weekly window resets days out, and a billing cycle can end in a
    /// different year — the access spike found a Codex subscription term ending
    /// in 2027, which rendered as "resets 09:00" and read as this morning.
    static func instantText(
        _ instant: Date,
        now: Date,
        formatting: QuotaFormatting = .current
    ) -> String {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = formatting.locale
        calendar.timeZone = formatting.timeZone

        // A local, not a `static let`: `DateFormatter` is not `Sendable`.
        let formatter = DateFormatter()
        formatter.locale = formatting.locale
        formatter.timeZone = formatting.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = calendar.isDate(instant, inSameDayAs: now) ? .none : .medium
        return formatter.string(from: instant)
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
    ///
    /// `now` is load-bearing: it decides whether the instant needs its date.
    static func rowText(
        for window: RateWindow,
        now: Date,
        formatting: QuotaFormatting = .current
    ) -> String {
        let label: String
        let verb: String
        switch window.kind {
        case .rollingFiveHours:
            label = "5h"
            verb = "resets"
        case .weekly:
            label = "Week"
            verb = "resets"
        case .billingCycle:
            // "ends", not "resets". A subscription *term* end returns no
            // capacity — the spike found a Codex term ending in 2027 — and even
            // a monthly cycle boundary is the end of a period rather than a
            // quota refill.
            label = "Cycle"
            verb = "ends"
        }

        let reset = instantText(window.resetAt, now: now, formatting: formatting)

        guard let fraction = window.usedFraction else {
            return "\(label) — usage unknown, \(verb) \(reset)"
        }
        return "\(label) \(Int((fraction * 100).rounded()))% — \(verb) \(reset)"
    }
}
