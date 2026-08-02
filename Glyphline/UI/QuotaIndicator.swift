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

/// What a window's countdown says is about to happen to it.
///
/// A choice of two, not a translated word, because every phrase the choice
/// produces is written out whole in the catalog. The verb used to travel through
/// the code as an already-localised `String` dropped into a `%@`, which handed a
/// translator a bare "resets" and no sight of the row it lands in.
enum QuotaVerb: Equatable, Sendable {
    /// The window refills: the five-hour and weekly quotas.
    case resets
    /// The window merely ends and returns no capacity: a subscription term.
    case ends
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
    /// Which failure `message` states, when it states one. Nil when the message
    /// is not a failure, or when there is no message at all.
    var failureCode: RateWindowFailureCode?

    init(
        accountID: UUID,
        displayName: String,
        windows: [QuotaWindowState],
        message: String? = nil,
        failureCode: RateWindowFailureCode? = nil
    ) {
        self.accountID = accountID
        self.displayName = displayName
        self.windows = windows
        self.message = message
        self.failureCode = failureCode
    }
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
    /// Which failure `message` states, when it states one. Carried through from
    /// the source so the dashboard can decide whether the user has something to
    /// do without reading a translated sentence.
    var failureCode: RateWindowFailureCode?

    init(
        id: UUID,
        displayName: String,
        message: String? = nil,
        failureCode: RateWindowFailureCode? = nil,
        rows: [QuotaBarRow]
    ) {
        self.id = id
        self.displayName = displayName
        self.message = message
        self.rows = rows
        self.failureCode = failureCode
    }

    /// True when the group would render its account heading over nothing at all.
    ///
    /// An account with no quota *source* always carries a `message` — the
    /// coordinator sets one before it ever gives up — so this is exactly the
    /// other case: a source exists, it answered, and it had no active window to
    /// report. Those two are distinguishable here only because of that
    /// invariant, and this property is where the app relies on it.
    var isSilent: Bool {
        message == nil && rows.isEmpty
    }
}

enum QuotaIndicator {
    /// Shown in place of the bars when a group is silent. Deliberately not an
    /// error and not "unavailable": the subscription is fine and its source
    /// answered, there is simply no active window yet. An account heading with
    /// nothing under it reads as a broken row, so no group renders headless.
    static let noQuotaReportedMessage = String(
        localized: "No quota reported yet.",
        comment: "Shown in place of the bars when a source answered but reported no active window."
    )

    /// Stands in for the reset instant on a window that has none. Both surfaces
    /// read this one constant so a row and a bar cannot start wording the same
    /// fact differently.
    ///
    /// Not "unknown" and not "never": the app knows exactly what it was told —
    /// there is no window running, so there is nothing to wait for. Deliberately
    /// carries no verb, because "resets never" would be a claim about the
    /// future and "resets —" would be a gap.
    static let noActiveWindowText = String(
        localized: "no active window",
        comment: "Stands in for the reset instant on a window that has none. Lower case: it sits inside a longer row."
    )

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

    /// The one freshness predicate. The light and the rendered rows both reach
    /// it — a rule applied at one site and forgotten at the other is the mistake
    /// this feature kept making.
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
    ///
    /// The converse is deliberately NOT symmetric: a fraction without a reset
    /// instant decides headroom perfectly well. An unused subscription reports
    /// exactly that — 0% consumed, no window running — and it is the most
    /// available account there is. Requiring an instant here would have hidden
    /// every freshly added subscription behind a grey light.
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
    /// `.formatted(.relative(...))`, because the system style rounds to a single
    /// unit: it turns 3h 20m into "in 3 hours" and loses exactly the precision
    /// the row exists for.
    ///
    /// `verb` keeps the distinction the labels carry: a billing cycle *ends*, it
    /// does not reset, because a subscription term end returns no capacity.
    ///
    /// It arrives as a `QuotaVerb`, not as an already-localised word, so that
    /// each of the six results is a whole phrase in the catalog. It used to be a
    /// translated fragment landing in a `%@` here, which reads as English and as
    /// nothing else: a translator saw "resets" alone, with no way to know it
    /// would be followed by a duration, a clock time, or "any moment", and no
    /// language agrees with English about where a verb goes.
    static func remainingText(until instant: Date, now: Date, verb: QuotaVerb) -> String {
        let remaining = instant.timeIntervalSince(now)

        // Past due carries no verb: "resets in -5m" is nonsense, and "ended"
        // would claim a refill happened that this app did not observe.
        guard remaining > 0 else {
            return String(localized: "due now", comment: "Quota row when the reset instant has already passed and no new figure has arrived yet. Lower case: it sits inside a longer row.")
        }
        guard remaining >= 60 else {
            switch verb {
            case .resets:
                return String(
                    localized: "resets any moment",
                    comment: "Quota row with under a minute left on a window that refills. Lower case: it sits inside a longer row."
                )
            case .ends:
                return String(
                    localized: "ends any moment",
                    comment: "Quota row with under a minute left on a subscription term, which returns no capacity. Lower case: it sits inside a longer row."
                )
            }
        }

        let duration = compactDuration(remaining)
        switch verb {
        case .resets:
            return String(
                localized: "resets in \(duration)",
                comment: "Quota row countdown on a window that refills. The placeholder is a compact duration such as '3h 20m'. Lower case: it sits inside a longer row."
            )
        case .ends:
            return String(
                localized: "ends in \(duration)",
                comment: "Quota row countdown on a subscription term, which returns no capacity. The placeholder is a compact duration such as '4d 6h'. Lower case: it sits inside a longer row."
            )
        }
    }

    /// How long the window itself spans, which is what makes its start
    /// derivable from its reset instant.
    ///
    /// A billing cycle deliberately has none: its length is whatever the
    /// subscription says, a month or a year, and guessing one would put a
    /// confident prediction on the window least able to support it.
    /// Internal rather than private since the dashboard cards place their pace
    /// marker against the same lengths; a second table of window spans is how
    /// two surfaces start disagreeing about where a window began.
    static func span(of kind: RateWindowKind) -> TimeInterval? {
        switch kind {
        case .rollingFiveHours: 5 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        case .billingCycle: nil
        }
    }

    /// Whether this window survives to its own reset at the pace it has been
    /// consumed so far — "on track", or when it will not, "empty in …".
    ///
    /// Averaged across the window rather than differentiated between readings.
    /// The provider quantises `usedFraction` to whole percent, so consecutive
    /// samples are usually identical: a derivative would read zero for twenty
    /// minutes and then spike as the figure steps by one. Averaging also means
    /// this needs no sample history at all — the window's start is `resetAt`
    /// minus its own span, so a verdict exists from the first reading rather
    /// than after days of collection.
    ///
    /// A healthy window says so rather than staying quiet. Silence was the first
    /// design, on the grounds that a note on every row is noise; in use it was
    /// indistinguishable from the feature not running. The five-hour rows never
    /// showed a prediction — none of them was ever unhealthy — and that read as
    /// a calculation that only applied to the weekly window.
    ///
    /// `nil` remains for the windows there is genuinely nothing to say about:
    /// no reset instant, no reported fraction, nothing consumed yet, or a
    /// billing cycle, whose span is whatever the subscription says.
    static func paceText(for window: RateWindow, now: Date) -> String? {
        guard let resetAt = window.resetAt,
              let span = span(of: window.kind),
              let used = window.usedFraction,
              // Nothing consumed is not a pace of zero, it is no pace at all;
              // and a window already spent has its answer in the bar.
              used > 0, used < 1
        else { return nil }

        let elapsed = now.timeIntervalSince(resetAt.addingTimeInterval(-span))
        guard elapsed > 0 else { return nil }

        let remaining = (1 - used) * elapsed / used
        guard remaining < resetAt.timeIntervalSince(now) else {
            return String(
                localized: "on track",
                comment: "Quota pace note: this window survives to its own reset at the pace so far."
            )
        }

        return String(
            localized: "empty in \(compactDuration(remaining))",
            comment: "Quota pace note when the window will not survive to its reset. The placeholder is a duration such as '1h 40m'."
        )
    }

    /// "3h 20m", "45m", "4d 6h". Every component floors, so the figure is always
    /// a lower bound on the wait rather than an optimistic round-up.
    private static func compactDuration(_ interval: TimeInterval) -> String {
        // Rounded to the second before the components are taken. These intervals
        // are increasingly computed rather than measured, and a pace
        // extrapolation lands on 33 599.999 999 where the arithmetic means
        // 33 600 — flooring that raw reports a minute less than the figure it
        // came from, for no reason a reader could ever discover.
        let totalMinutes = Int(interval.rounded() / 60)
        let days = totalMinutes / (60 * 24)
        if days >= 1 {
            // The hours are carried for exactly the reason the minutes are
            // carried below. A bare "4d" hides up to another 23 hours, which is
            // the single-unit rounding `remainingText` documents itself as
            // refusing — and this branch did it anyway.
            let hours = (totalMinutes / 60) % 24
            return hours == 0
                ? String(localized: "\(days)d", comment: "Compact duration, whole days only. Placeholder: a number of days.")
                : String(
                    localized: "\(days)d \(hours)h",
                    comment: "Compact duration. Placeholders: a number of days and a number of hours."
                )
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 1 {
            return minutes == 0
                ? String(localized: "\(hours)h", comment: "Compact duration, whole hours only. Placeholder: a number of hours.")
                : String(
                    localized: "\(hours)h \(minutes)m",
                    comment: "Compact duration. Placeholders: a number of hours and a number of minutes."
                )
        }
        return String(localized: "\(minutes)m", comment: "Compact duration under an hour. Placeholder: a number of minutes.")
    }

    /// The menu bar's fixed mark.
    ///
    /// A named constant rather than a literal at the call site so it can be
    /// asserted: `Image(systemName:)` given a name that does not exist renders
    /// *nothing* and reports no error, so a typo or a renamed symbol produces an
    /// invisible menu bar item — a failure that looks exactly like the app not
    /// running at all.
    ///
    /// Placeholder for custom artwork echoing the app icon's gauge.
    static let menuBarSymbolName = "gauge.with.needle"

    /// What VoiceOver reads for the menu bar item.
    ///
    /// Deliberately still state-dependent even though the menu bar glyph is now
    /// fixed. A sighted user reads the state from the panel — its header dot and
    /// the tinted bar on every row. A VoiceOver user would otherwise have to open
    /// the panel to learn anything at all, so the accessible name carries the
    /// state and saves them the trip. That it says more than the glyph shows is
    /// intentional, not an oversight.
    static func accessibilityLabel(for state: QuotaLightState) -> String {
        switch state {
        case .green:
            String(localized: "Glyphline — quota available", comment: "VoiceOver name for the menu bar item. 'Glyphline' is the app's name and stays.")
        case .red:
            String(localized: "Glyphline — quota exhausted", comment: "VoiceOver name for the menu bar item. 'Glyphline' is the app's name and stays.")
        case .grey:
            String(localized: "Glyphline — quota unknown", comment: "VoiceOver name for the menu bar item. 'Glyphline' is the app's name and stays.")
        }
    }

    /// The menu blocks, one per account, with the freshness bound applied.
    ///
    /// This exists so the view cannot choose a bound of its own — the same
    /// reason `quotaLight` is resolved on the coordinator.
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

    /// The verb each window kind takes, beside its short name. `rowText` and
    /// `barGroups` both read it, so a surface cannot start saying "Cycle resets"
    /// on its own.
    ///
    /// The label itself comes from `RateWindowKind.shortName`. The dashboard's
    /// cards have room for the spelled-out `longName` and use that; both live on
    /// the kind so the two readings of one window cannot be renamed apart.
    ///
    /// "ends", not "resets", for the cycle. A subscription *term* end returns no
    /// capacity — the spike found a Codex term ending in 2027 — and even a
    /// monthly cycle boundary is the end of a period rather than a quota refill.
    static func labelAndVerb(for kind: RateWindowKind) -> (label: String, verb: QuotaVerb) {
        switch kind {
        case .rollingFiveHours: (kind.shortName, .resets)
        case .weekly: (kind.shortName, .resets)
        case .billingCycle: (kind.shortName, .ends)
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
                failureCode: state.failureCode,
                rows: state.windows.map { windowState in
                    let (label, verb) = labelAndVerb(for: windowState.window.kind)
                    let asOf = isFresh(windowState, now: now, freshness: freshness)
                        ? nil
                        : windowState.believableSince
                    // Remaining time, not a clock time: the bars are read to
                    // decide whether to wait, and "13:10" makes the reader
                    // subtract. Built against the injected `now` so it stays
                    // testable.
                    //
                    // With no reset instant there is no wait to state, so the
                    // slot says what is actually true rather than borrowing a
                    // verb: "resets in …" over a window that is not running
                    // would invent a countdown.
                    let remaining = windowState.window.resetAt.map {
                        remainingText(until: $0, now: now, verb: verb)
                    } ?? noActiveWindowText

                    // The inversion lives here and nowhere else: `usedFraction`
                    // is what the provider reports and what `isPlausible`
                    // validates, and it stays as it is.
                    let left = remainingFraction(forUsed: windowState.window.usedFraction)

                    var detail: String
                    if let left {
                        // "left", not a bare percentage: "45%" reads either way,
                        // and the whole point of the change is that the reader
                        // no longer has to subtract.
                        detail = String(
                            localized: "\(Int((left * 100).rounded()))% left · \(remaining)",
                            comment: "Quota bar detail. Placeholders: the percentage left, and the countdown ('resets in 3h 20m')."
                        )
                    } else {
                        detail = String(
                            localized: "usage unknown · \(remaining)",
                            comment: "Quota bar detail with no reported fraction. The placeholder is the countdown."
                        )
                    }

                    // Appended rather than replacing anything. Absent only where
                    // there is nothing to say — see `paceText`.
                    if let pace = paceText(for: windowState.window, now: now) {
                        detail = String(
                            localized: "\(detail) · \(pace)",
                            comment: "Quota bar detail with the pace note appended. Placeholders: the detail so far, and the pace note."
                        )
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
    ///
    /// A window with no reset instant says so in place of the instant. The verb
    /// goes with the instant and not with the row, so `.billingCycle` still
    /// reads "ends" wherever there is something to end.
    static func rowText(
        for window: RateWindow,
        now: Date,
        asOf: Date? = nil,
        formatting: QuotaFormatting = .current
    ) -> String {
        let (label, verb) = labelAndVerb(for: window.kind)

        let tail = window.resetAt.map { resetAt -> String in
            let instant = instantText(resetAt, now: now, formatting: formatting)
            switch verb {
            case .resets:
                return String(
                    localized: "resets \(instant)",
                    comment: "Menu row tail on a window that refills. The placeholder is a clock time or a date, e.g. 'resets 14:00'. Lower case: it sits inside a longer row."
                )
            case .ends:
                return String(
                    localized: "ends \(instant)",
                    comment: "Menu row tail on a subscription term, which returns no capacity. The placeholder is a clock time or a date, e.g. 'ends 31 Oct 2026'. Lower case: it sits inside a longer row."
                )
            }
        } ?? noActiveWindowText

        let head: String
        if let fraction = window.usedFraction {
            head = String(
                localized: "\(label) \(Int((fraction * 100).rounded()))% — \(tail)",
                comment: "Menu row. Placeholders: the window's short name, the percentage used, and the tail ('resets 14:00')."
            )
        } else {
            head = String(
                localized: "\(label) — usage unknown, \(tail)",
                comment: "Menu row with no reported fraction. Placeholders: the window's short name and the tail."
            )
        }

        guard let asOf else { return head }
        return String(
            localized: "\(head) (as of \(instantText(asOf, now: now, formatting: formatting)))",
            comment: "Menu row qualified with when the figure was last believed. Placeholders: the row so far, and an instant."
        )
    }
}
