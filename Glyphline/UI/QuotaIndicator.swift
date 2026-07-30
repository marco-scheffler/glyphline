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

/// One account's block in the menu, with the freshness bound already applied.
///
/// The view receives this rather than the raw windows and a bound to apply
/// itself. `message` and `rows` are both rendered: the message explains why the
/// short windows are missing, which is not a reason to hide a reset instant the
/// app does know. Since no account resolves to a quota source today, that
/// cost-derived billing cycle is the only genuine quota datum a real user has,
/// and the either/or the menu used to draw made it invisible.
struct QuotaRowGroup: Identifiable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var message: String?
    var rows: [String]
}

/// One window as a drawable row: the number left unrendered so a bar can be
/// drawn from it, with the freshness bound already applied.
///
/// `asOf` is the same verdict `rowGroups` renders as its " (as of …)" qualifier,
/// decided by the same predicate. A view receiving raw states could pick its own
/// bound, which is precisely the disagreement this feature kept reintroducing.
struct QuotaBarRow: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    /// `nil` means the provider reported no consumed fraction. A bar must then
    /// be absent rather than empty — 0% is a wrong number, not a missing one.
    var fraction: Double?
    var detail: String
    /// Non-nil exactly when the window is past the freshness bound; the instant
    /// the figure was last believed.
    var asOf: Date?
}

/// One account's block on a dashboard card. The structural twin of
/// `QuotaRowGroup`, carrying the same message and the same rows.
struct QuotaBarGroup: Identifiable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var message: String?
    var rows: [QuotaBarRow]
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

    /// The menu blocks, one per account, with the freshness bound applied.
    ///
    /// This exists so the view cannot choose a bound of its own — the same
    /// reason `quotaLight` and `nextFreeText` are resolved on the coordinator.
    /// The rows were the one consumer that applied no bound at all: an
    /// observation the light had already discarded still printed "5h 62% —
    /// resets 14:00", flatly, as fact, under a grey icon and a missing header.
    static func rowGroups(
        for states: [QuotaAccountState],
        now: Date,
        freshness: TimeInterval,
        formatting: QuotaFormatting = .current
    ) -> [QuotaRowGroup] {
        states.map { state in
            QuotaRowGroup(
                id: state.accountID,
                displayName: state.displayName,
                message: state.message,
                rows: state.windows.map { windowState in
                    // A stale window is shown with the instant it was last
                    // believed rather than dropped: the reset instant stays
                    // useful, and the qualifier stops the figure reading as
                    // current.
                    let asOf = isFresh(windowState, now: now, freshness: freshness)
                        ? nil
                        : windowState.believableSince

                    return rowText(
                        for: windowState.window,
                        now: now,
                        asOf: asOf,
                        formatting: formatting
                    )
                }
            )
        }
    }

    /// The one place window kinds get their words. `rowText` and `barGroups` both
    /// read it, so a surface cannot start saying "Cycle resets" on its own.
    ///
    /// "ends", not "resets", for the cycle. A subscription *term* end returns no
    /// capacity — the spike found a Codex term ending in 2027 — and even a
    /// monthly cycle boundary is the end of a period rather than a quota refill.
    static func labelAndVerb(for kind: RateWindowKind) -> (label: String, verb: String) {
        switch kind {
        case .rollingFiveHours: ("5h", "resets")
        case .weekly: ("Week", "resets")
        case .billingCycle: ("Cycle", "ends")
        }
    }

    /// The same groups `rowGroups` produces, with the numbers left unrendered so a
    /// bar can be drawn. Freshness is decided here, by the same predicate, for the
    /// same reason: a view that received raw states could pick its own bound.
    static func barGroups(
        for states: [QuotaAccountState],
        now: Date,
        freshness: TimeInterval,
        formatting: QuotaFormatting = .current
    ) -> [QuotaBarGroup] {
        states.map { state in
            QuotaBarGroup(
                id: state.accountID,
                displayName: state.displayName,
                message: state.message,
                rows: state.windows.map { windowState in
                    let (label, verb) = labelAndVerb(for: windowState.window.kind)
                    let asOf = isFresh(windowState, now: now, freshness: freshness)
                        ? nil
                        : windowState.believableSince
                    let reset = instantText(windowState.window.resetAt, now: now, formatting: formatting)

                    let detail: String
                    if let fraction = windowState.window.usedFraction {
                        detail = "\(Int((fraction * 100).rounded()))% — \(verb) \(reset)"
                    } else {
                        detail = "usage unknown, \(verb) \(reset)"
                    }

                    return QuotaBarRow(
                        id: windowState.window.kind.rawValue,
                        label: label,
                        fraction: windowState.window.usedFraction,
                        detail: detail,
                        asOf: asOf
                    )
                }
            )
        }
    }

    /// One window as a menu row. A missing fraction says so rather than
    /// rendering as 0%, which would read as "untouched".
    ///
    /// `now` is load-bearing: it decides whether the instant needs its date.
    ///
    /// `asOf` is set exactly when the window is past the freshness bound. The row
    /// then names when the figure was last believed, because a percentage the app
    /// has formally decided not to trust must not be printed as a plain fact.
    static func rowText(
        for window: RateWindow,
        now: Date,
        asOf: Date? = nil,
        formatting: QuotaFormatting = .current
    ) -> String {
        let (label, verb) = labelAndVerb(for: window.kind)

        let reset = instantText(window.resetAt, now: now, formatting: formatting)

        let head: String
        if let fraction = window.usedFraction {
            head = "\(label) \(Int((fraction * 100).rounded()))% — \(verb) \(reset)"
        } else {
            head = "\(label) — usage unknown, \(verb) \(reset)"
        }

        guard let asOf else { return head }
        return "\(head) (as of \(instantText(asOf, now: now, formatting: formatting)))"
    }
}
