import Foundation

enum QuotaLightState: Equatable, Sendable {
    case green
    case red
    case grey
}

/// How a single window reads: fine, close to the limit, spent, or unknown.
///
/// Decided in `QuotaIndicator` and carried on the row, never derived in a view —
/// two surfaces draw these rows, and a threshold applied in one of them is how
/// the card and the panel start disagreeing about the same number.
enum QuotaSeverity: Equatable, Sendable {
    case normal
    case warning
    case exhausted
    case unknown
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
    /// How much of the window is **left**, not how much is used — the bar drains
    /// as quota is consumed. Named for the meaning so the sense cannot be
    /// flipped a second time by someone reading a bare `fraction`.
    ///
    /// `nil` means the provider reported no consumed fraction. A bar must then
    /// be absent rather than empty — 0% is a wrong number, not a missing one,
    /// and 100% left would be a confidently wrong one.
    var remainingFraction: Double?
    var detail: String
    /// Non-nil exactly when the window is past the freshness bound; the instant
    /// the figure was last believed.
    var asOf: Date?
    /// Decided from `remainingFraction` by `QuotaIndicator.severity(forRemaining:)`,
    /// so the colour a bar takes and the state the light reports come from one rule.
    var severity: QuotaSeverity = .unknown
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
    /// The one exhaustion threshold in the app. `hasHeadroom` — and therefore
    /// the menu bar light — and a row's `.exhausted` verdict both compare
    /// against *this* constant rather than against two literals that happen to
    /// agree today.
    static let exhaustedFraction = 1.0

    /// The same threshold expressed on the remaining fraction — *derived* from
    /// `exhaustedFraction`, not a second literal that happens to agree. Rows are
    /// judged on what is left, the light on what is used, and this identity is
    /// the only reason the two cannot drift apart.
    static let exhaustedRemainingFraction = 1 - exhaustedFraction

    /// Advisory only, and deliberately above `exhaustedRemainingFraction`: a
    /// little left, but not nothing. The light has no opinion about this band
    /// and never claims "no warning" — it says "usable" or "known exhausted" —
    /// so an amber bar can never contradict a green icon.
    static let lowRemainingFraction = 0.2

    /// What is left of a window, from what the provider says was used. `nil`
    /// stays `nil`: an unknown usage is not "100% left".
    static func remainingFraction(forUsed used: Double?) -> Double? {
        guard let used else { return nil }
        return 1 - used
    }

    /// A window's verdict, read off the remaining fraction. `nil` is `.unknown`:
    /// a missing fraction is not "nothing left" and not "everything left".
    static func severity(forRemaining remaining: Double?) -> QuotaSeverity {
        guard let remaining else { return .unknown }
        if remaining <= exhaustedRemainingFraction { return .exhausted }
        if remaining <= lowRemainingFraction { return .warning }
        return .normal
    }

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
        return fractions.allSatisfy { $0 < exhaustedFraction }
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

        // A value type, not a `DateFormatter`: `Date.FormatStyle` is `Sendable`,
        // so this path carries no non-Sendable class instance at all.
        //
        // `.numeric`, not `.medium`: a medium date spells the month, and a
        // spelled month is a word, so it follows the *system* language —
        // "resets 31. Okt. 2026" inside an English menu on a German Mac. The
        // fix is the numeral form rather than a forced English locale: forcing
        // English would fix the word and break the field order, printing
        // "10/31/2026" to a reader who reads the day first. `.numeric` keeps
        // the order local, spells nothing, and — unlike `DateFormatter`'s
        // `.short` — writes the year in full. That last part is not cosmetic:
        // the row this date exists for is a subscription term ending in 2027,
        // and "3/9/27" is the same ambiguity the date was added to remove.
        //
        // The style is chosen here and not in `QuotaFormatting` because that
        // type carries *where* the reader is, not how much of the date to show
        // — that is this function's own same-day decision.
        let style = Date.FormatStyle(
            date: calendar.isDate(instant, inSameDayAs: now) ? .omitted : .numeric,
            time: .shortened,
            locale: formatting.locale,
            timeZone: formatting.timeZone
        )
        return instant.formatted(style)
    }

    /// How long until an instant, as words rather than a clock time.
    ///
    /// A clock time makes the reader do the arithmetic, and for the weekly
    /// window a bare weekday says almost nothing. This answers the question the
    /// reader actually has: how long do I wait.
    ///
    /// Composed by hand from the interval rather than through
    /// `.formatted(.relative(...))`. Two reasons: these are *words*, and the
    /// app's words are English wherever the Mac is set to — the relative style
    /// would follow the system language and print "in 3 Stunden" into an English
    /// panel — and the system style rounds to a single unit, which turns 3h 20m
    /// into "in 3 hours" and loses exactly the precision the row exists for.
    ///
    /// `verb` keeps the distinction the labels carry: a billing cycle *ends*, it
    /// does not reset, because a subscription term end returns no capacity.
    static func remainingText(until instant: Date, now: Date, verb: String) -> String {
        let remaining = instant.timeIntervalSince(now)

        // Past due carries no verb: "resets in -5m" is nonsense, and "ended"
        // would claim a refill happened that this app did not observe.
        guard remaining > 0 else { return "due now" }
        guard remaining >= 60 else { return "\(verb) any moment" }

        return "\(verb) in \(compactDuration(remaining))"
    }

    /// "3h 20m", "45m", "4d". Every component floors, so the figure is always a
    /// lower bound on the wait rather than an optimistic round-up.
    private static func compactDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / (60 * 24)
        if days >= 1 { return "\(days)d" }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 1 {
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
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
                    // Remaining time, not a clock time: the bars are read to
                    // decide whether to wait, and "13:10" makes the reader
                    // subtract. Built against the injected `now` so it stays
                    // testable.
                    let remaining = remainingText(
                        until: windowState.window.resetAt,
                        now: now,
                        verb: verb
                    )

                    // The inversion lives here and nowhere else: `usedFraction`
                    // is what the provider reports and what `isPlausible`
                    // validates, and it stays as it is.
                    let left = remainingFraction(forUsed: windowState.window.usedFraction)

                    let detail: String
                    if let left {
                        // "left", not a bare percentage: "45%" reads either way,
                        // and the whole point of the change is that the reader
                        // no longer has to subtract.
                        detail = "\(Int((left * 100).rounded()))% left · \(remaining)"
                    } else {
                        detail = "usage unknown · \(remaining)"
                    }

                    return QuotaBarRow(
                        id: windowState.window.kind.rawValue,
                        label: label,
                        remainingFraction: left,
                        detail: detail,
                        asOf: asOf,
                        severity: severity(forRemaining: left)
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
