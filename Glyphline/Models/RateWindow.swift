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
        case .rollingFiveHours:
            String(localized: "5h", comment: "Terse name of the rolling five-hour quota window, menu bar row: the quota that refills every five hours. Digit plus unit letter; keep it to two or three characters.")
        case .weekly:
            // Its own key rather than the bare word: the spend picker also draws
            // "Week", and there it names a length of time the reader chose. Here
            // it names the provider's rolling weekly rate-limit window. English
            // spells both the same; a language that does not would have had to
            // pick one meaning for both.
            String(
                localized: "quotaWindow.weekly.short",
                defaultValue: "Week",
                comment: "Terse name of the weekly quota window, menu bar row, beside '5h' and 'Cycle'. Names the provider's rolling weekly rate-limit window, not a calendar week. Keep it short — the row is a few points wide."
            )
        case .billingCycle:
            String(localized: "Cycle", comment: "Terse name of the billing cycle window, menu bar row: the subscription's own billing period. Keep it short.")
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
        case .rollingFiveHours:
            String(localized: "5-hour", comment: "Spelled-out name of the rolling five-hour quota window, dashboard card")
        case .weekly:
            String(localized: "Weekly", comment: "Spelled-out name of the weekly quota window, dashboard card")
        case .billingCycle:
            String(localized: "Billing cycle", comment: "Spelled-out name of the billing cycle window, dashboard card")
        }
    }
}

/// Which limit an observation belongs to.
///
/// The kind alone stopped being enough when the provider began reporting a
/// weekly allowance confined to one model beside the weekly limit on the whole
/// subscription. Both are `.weekly`, so every place that tells windows apart —
/// the stored series, freshness, warnings, the rows a view draws — keys on this
/// pair rather than on the kind.
struct RateWindowID: Hashable, Sendable {
    var kind: RateWindowKind
    /// The model the limit is confined to, as the provider spells it, or `nil`
    /// for a limit on the whole subscription.
    var model: String?

    /// The model's own name where there is no room: in the menu bar row "Fable"
    /// says which limit it is, and the provider only confines weekly limits to a
    /// model. A product name, so it is never translated.
    var shortName: String {
        model ?? kind.shortName
    }

    var longName: String {
        guard let model else { return kind.longName }
        return String(
            localized: "quotaWindow.model.long",
            defaultValue: "\(model) · \(kind.longName)",
            comment: "Spelled-out name of a quota window confined to one model, dashboard card and notification. Placeholders: the model's product name such as 'Fable' (never translated), then the window's name such as 'Weekly'."
        )
    }

    /// A stable string for a view's row identity. The kind's raw value is what
    /// it was before models existed, so a plain window keeps its identity.
    var rowID: String {
        model.map { "\(kind.rawValue)/\($0)" } ?? kind.rawValue
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
    /// The model this limit is confined to, or `nil` for a limit on the whole
    /// subscription — which every window was until the provider began reporting
    /// a weekly allowance for one model.
    var model: String? = nil

    var id: RateWindowID { RateWindowID(kind: kind, model: model) }

    /// Whether this window can say the subscription is spent. A model's own
    /// allowance cannot: with it gone every other model still runs, so it may
    /// colour its own row but never the light.
    var decidesHeadroom: Bool { model == nil }

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
