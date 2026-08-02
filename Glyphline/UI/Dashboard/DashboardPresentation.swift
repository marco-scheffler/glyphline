import Foundation
import SwiftUI

/// One period of machine-wide local usage in the two shapes the dashboard draws:
/// a gap-free daily series and a cost-ranked model mix.
///
/// Both are built from one fetch of the same rows, so the chart and the mix
/// cannot end up describing two different reads of the ledger.
struct LocalUsageBreakdown: Equatable, Sendable {
    var series: DailyUsageSeries
    var mix: ModelMix
}

/// The dashboard's arithmetic and its wording, kept out of the view.
///
/// Everything here is a pure function of its arguments. The layout itself has no
/// surface a test can hold on to, so the parts that *can* be wrong in a way a
/// reader would not notice — a padded axis, a percentage against a median, a
/// plural — live here where they can be asserted.
enum DashboardPresentation {
    // MARK: - Padding the series to a period

    /// The period's days, with the leading edge padded out to zero days.
    ///
    /// `DailyUsageSeries` begins at the first day that has rows, not at
    /// `now - N days`. A "last 30 days" chart built straight from it would draw a
    /// shorter axis after a quiet fortnight instead of a run of zero bars — the
    /// same lie the gap-free rule prevents, moved to the other end of the range.
    ///
    /// - Parameter days: the period's length, today included. Nil means all time,
    ///   which has no leading edge to pad to.
    static func entries(
        of series: DailyUsageSeries,
        over days: Int?,
        calendar: Calendar = LocalUsagePeriod.utcCalendar
    ) -> [DailyUsageEntry] {
        guard let days, days > 0 else { return series.entries }

        guard let start = calendar.date(
            byAdding: .day,
            value: -(days - 1),
            to: series.referenceDay
        ) else { return series.entries }

        // The end is today, or a later day if the series carries one. A row dated
        // in the future is a defect worth seeing, not one worth silently hiding.
        let end = max(series.referenceDay, series.entries.last?.day ?? series.referenceDay)

        var known: [Date: DailyUsageEntry] = [:]
        for entry in series.entries {
            known[entry.day] = entry
        }

        var padded: [DailyUsageEntry] = []
        var day = start
        while day <= end {
            padded.append(known[day] ?? Self.zeroDay(day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return padded
    }

    /// A day nothing was recorded on. Its cost stays nil rather than zero, for
    /// the same reason an unpriced model's does: nobody billed nothing, nothing
    /// simply happened.
    static func zeroDay(_ day: Date) -> DailyUsageEntry {
        DailyUsageEntry(
            day: day,
            statistics: LocalUsageStatistics(models: [], estimatedAmountMicros: nil, currency: nil)
        )
    }

    // MARK: - Today against the median

    /// Today's volume set against the median of the recent completed days.
    ///
    /// `isAbove` is nil when there is nothing to compare against, so the view can
    /// drop the tint rather than pick a colour for a sentence.
    struct MedianComparison: Equatable, Sendable {
        var text: String
        var isAbove: Bool?
    }

    static let noMedianYetText = "No completed day to compare against yet."

    /// - Parameter median: `DailyUsageSeries.median(days:)`, which is nil on a
    ///   machine that has not finished a single day. That is a sentence, not a
    ///   blank: a dash here would read as "zero".
    static func todayVersusMedian(
        todayTokens: Int64,
        median: Int64?,
        days: Int
    ) -> MedianComparison {
        guard let median else {
            return MedianComparison(text: noMedianYetText, isAbove: nil)
        }
        guard median > 0 else {
            return MedianComparison(
                text: "Nothing recorded on the last \(days) completed days.",
                isAbove: nil
            )
        }

        let change = (Double(todayTokens - median) / Double(median) * 100).rounded()
        guard change != 0 else {
            return MedianComparison(text: "Level with the \(days)-day median", isAbove: nil)
        }

        let sign = change > 0 ? "+" : "−"
        let magnitude = Int(abs(change))
        return MedianComparison(
            text: "\(sign)\(magnitude) % vs. \(days)-day median",
            isAbove: change > 0
        )
    }

    // MARK: - The Agentverse call to action

    /// How the dashboard's Agents tile reads and whether it is allowed to
    /// shout.
    ///
    /// `isUrgent` drives amber, matching the plumbob over a waiting agent's
    /// head so both surfaces speak one language. With nobody waiting it goes
    /// quiet: a dashboard that always looks urgent stops meaning anything.
    ///
    /// The counts are boxed up by the tile; `headline` says the same thing in
    /// plain language, which reads at a glance in a way three numbered boxes do
    /// not quite manage.
    struct AgentverseCallToAction: Equatable, Sendable {
        var waiting: Int
        var working: Int
        var resting: Int
        var headline: String
        var isUrgent: Bool
        /// No sessions at all — neither waiting nor working nor parked. The
        /// tile still opens the map, it simply says there is nobody in it.
        var isEmpty: Bool
    }

    static func callToAction(waiting: Int, working: Int, resting: Int) -> AgentverseCallToAction {
        let isEmpty = waiting + working + resting == 0

        let headline: String
        if isEmpty {
            headline = "No agents on this Mac"
        } else if waiting == 0 {
            headline = "Nobody is waiting on you"
        } else if waiting == 1 {
            headline = "1 agent is waiting on you"
        } else {
            headline = "\(waiting) agents are waiting on you"
        }

        return AgentverseCallToAction(
            waiting: waiting,
            working: working,
            resting: resting,
            headline: headline,
            isUrgent: waiting > 0,
            isEmpty: isEmpty
        )
    }

    // MARK: - Accounts that need the user

    /// An account something is wrong with, and what.
    struct AccountAttention: Identifiable, Equatable, Sendable {
        var id: UUID
        var accountName: String
        var reason: String
    }

    /// What a failed sync run says when it did not say anything itself.
    static let syncFailedReason = "The last sync failed."

    /// The accounts the user has to act on.
    ///
    /// Both inputs are state the app already keeps; there is no new per-account
    /// failure mechanism here. `QuotaBarGroup.message` is the reason the sync
    /// coordinator stores per account when a quota fetch fails — the same string
    /// the menu bar panel and the accounts list already show — and only the two
    /// of those the user can actually fix count as attention. The other input is
    /// the account's own last sync run, which carries the provider's message.
    ///
    /// A quota reason wins over a failed run for the same account: an expired
    /// sign-in is why the run failed, and naming the cause beats naming the
    /// symptom.
    ///
    /// Disabled accounts are skipped. Nothing is syncing them, so an old failure
    /// on one is not a task.
    static func accountsNeedingAttention(
        summaries: [AccountUsageSummary],
        quotaGroups: [QuotaBarGroup]
    ) -> [AccountAttention] {
        let quotaReasons = Dictionary(
            quotaGroups.map { ($0.id, $0.message) },
            uniquingKeysWith: { first, _ in first }
        )

        return summaries.compactMap { summary in
            guard summary.account.isEnabled else { return nil }

            if let reason = quotaReasons[summary.account.id] ?? nil,
               RateWindowSourceError.userActionableMessages.contains(reason) {
                return AccountAttention(
                    id: summary.account.id,
                    accountName: summary.account.resolvedName,
                    reason: reason
                )
            }

            if let run = summary.latestSyncRun, run.status == .failed {
                return AccountAttention(
                    id: summary.account.id,
                    accountName: summary.account.resolvedName,
                    reason: run.message ?? syncFailedReason
                )
            }

            return nil
        }
    }

    // MARK: - Quota cards

    /// One account's quota card, named and filled.
    ///
    /// Lives here rather than in the view because *which* name a card carries is
    /// a decision — the account's chosen name when there is one, the derived
    /// name otherwise — and a decision inside a `View` cannot be asserted.
    ///
    /// - Parameter state: what the sync coordinator last saw for this account,
    ///   matched by id by the caller. Nil means nothing has been seen yet.
    static func accountQuotaCard(
        summary: AccountUsageSummary,
        state: QuotaAccountState?,
        now: Date
    ) -> AccountQuotaCardModel {
        guard let state else {
            return AccountQuotaCardModel(
                id: summary.account.id,
                accountName: summary.account.resolvedName,
                providerName: summary.account.providerID.displayName,
                cards: [],
                message: "This account has not reported a quota yet."
            )
        }

        let cards = state.windows.compactMap { QuotaCardModel.make(for: $0.window, now: now) }
        return AccountQuotaCardModel(
            id: summary.account.id,
            accountName: summary.account.resolvedName,
            providerName: summary.account.providerID.displayName,
            cards: state.message == nil ? cards : [],
            // The provider's own explanation wins over ours, and a state that
            // reports no window at all still has to say so rather than leave the
            // account's card empty.
            message: state.message ?? (cards.isEmpty ? QuotaIndicator.noQuotaReportedMessage : nil)
        )
    }

    /// The banner's headline. A count, because the reasons are listed under it.
    static func attentionHeadline(count: Int) -> String {
        count == 1 ? "1 account needs attention" : "\(count) accounts need attention"
    }

    // MARK: - Chart slices

    /// One model's contribution to one day, flattened for a stacked bar chart.
    struct DayModelSlice: Identifiable, Equatable, Sendable {
        var day: Date
        /// The name the legend shows. Never nil — an unnamed model gets a word,
        /// because a blank swatch names nothing.
        var model: String
        var tokens: Int64
        var id: String { "\(day.timeIntervalSince1970):\(model)" }
    }

    static let unknownModelLabel = "Unknown model"
    static let otherModelsLabel = "Other"

    // MARK: - Naming a model

    /// Display names for the identifiers the pricing catalog carries.
    ///
    /// Keyed on the undated identifier only: the dated variants are handled by
    /// stripping the suffix, not by listing them (see `modelDisplayName`).
    private static let modelDisplayNames: [String: String] = [
        "claude-fable-5": "Fable 5",
        "claude-opus-5": "Opus 5",
        "claude-opus-4-8": "Opus 4.8",
        "claude-sonnet-5": "Sonnet 5",
        "claude-sonnet-4-6": "Sonnet 4.6",
        "claude-haiku-4-5": "Haiku 4.5",
        "gpt-5.4": "GPT-5.4",
    ]

    /// What a model identifier is called on screen.
    ///
    /// Transcripts carry both the bare identifier and a dated build of the same
    /// model — `claude-haiku-4-5-20251001` is Haiku 4.5. Listing every dated
    /// variant would need editing on every model release, so the date is
    /// stripped and the remainder looked up instead.
    ///
    /// An identifier nobody has a name for is returned verbatim. A model this
    /// app has never seen is exactly the one worth noticing, and a raw
    /// `claude-something-9` tells more than a blank or a dropped row would.
    static func modelDisplayName(_ identifier: String) -> String {
        // Nothing to name. Falls back to the same words an absent model gets,
        // because an empty label draws an empty row.
        guard !identifier.isEmpty else { return unknownModelLabel }
        if let name = modelDisplayNames[identifier] { return name }
        if let undated = identifierWithoutDateSuffix(identifier),
           let name = modelDisplayNames[undated] {
            return name
        }
        return identifier
    }

    /// The identifier without a trailing `-YYYYMMDD`, or nil when it has none.
    private static func identifierWithoutDateSuffix(_ identifier: String) -> String? {
        let suffixLength = 9 // one hyphen plus eight digits
        guard identifier.count > suffixLength else { return nil }
        let suffix = identifier.suffix(suffixLength)
        guard suffix.first == "-",
              suffix.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return String(identifier.dropLast(suffixLength))
    }

    // MARK: - Colouring a model

    /// The approved model palette, keyed like `modelDisplayNames` on the undated
    /// identifier.
    ///
    /// The scheme carries two facts at once: the hue is the family and the
    /// lightness is the generation, so purple-heavy bars say "Opus" at a glance
    /// and the darker purple says "the older one". Swift Charts' default palette
    /// would order the colours by whichever model happened to appear first, which
    /// says nothing at all.
    private static let modelColorHexes: [String: UInt32] = [
        "claude-fable-5": 0xff_7a_b8,
        "claude-opus-5": 0xa9_7b_ff,
        "claude-opus-4-8": 0x8a_63_d6,
        "claude-sonnet-5": 0x5b_a9_ff,
        "claude-sonnet-4-6": 0x4a_86_c8,
        "claude-haiku-4-5": 0x3d_dc_91,
    ]

    /// What a model nobody has a colour for is drawn in.
    ///
    /// Grey rather than a seventh hue: letting the chart pick from its defaults
    /// would dress an unknown model in a known family's colour, and a reader who
    /// trusts the hue would misread the bill. Grey is the palette saying "this
    /// one is not in the scheme" — the visual half of the raw identifier
    /// `modelDisplayName` falls back to.
    private static let unknownModelColorHex: UInt32 = 0x8e_8e_93

    /// The colour a model is drawn in, everywhere it is drawn.
    ///
    /// The one source of model colour: the chart, its legend, the day detail and
    /// the Model Mix tile all read it, so a hue cannot mean two different models
    /// on the same screen.
    ///
    /// Dated builds are folded onto their model exactly as in `modelDisplayName`:
    /// `claude-haiku-4-5-20251001` is Haiku 4.5 and gets Haiku's green.
    static func modelColor(_ identifier: String) -> Color {
        Color(rgbHex: colorHex(identifier))
    }

    private static func colorHex(_ identifier: String) -> UInt32 {
        if let hex = modelColorHexes[identifier] { return hex }
        if let undated = identifierWithoutDateSuffix(identifier),
           let hex = modelColorHexes[undated] {
            return hex
        }
        return unknownModelColorHex
    }

    /// The models a legend can carry, ranked as `ModelMix` ranks them — by cost.
    ///
    /// Beyond `limit` the legend stops being a legend, so the tail is folded into
    /// one bucket rather than dropped. Dropping it would make the bars shorter
    /// than the day they describe.
    static func chartModels(from mix: ModelMix, limit: Int) -> [String] {
        Array(mix.entries.prefix(max(limit, 0)).map { $0.model ?? unknownModelLabel })
    }

    /// The days as chart rows, one per model per day, with every model outside
    /// `keeping` summed into `otherModelsLabel`.
    static func slices(for entries: [DailyUsageEntry], keeping models: [String]) -> [DayModelSlice] {
        let kept = Set(models)
        var slices: [DayModelSlice] = []

        for entry in entries {
            var other: Int64 = 0
            for model in entry.statistics.models where model.totalTokens > 0 {
                let name = model.model ?? unknownModelLabel
                if kept.contains(name) {
                    slices.append(DayModelSlice(day: entry.day, model: name, tokens: model.totalTokens))
                } else {
                    other += model.totalTokens
                }
            }
            if other > 0 {
                slices.append(DayModelSlice(day: entry.day, model: otherModelsLabel, tokens: other))
            }
        }

        return slices
    }

    /// The daily chart's style scale: what its legend prints, and in what
    /// colour.
    struct ChartStyleScale: Equatable {
        /// The series keys, which are also the legend's text.
        var domain: [String]
        var range: [Color]
    }

    /// The style scale for a set of slices, in the order they are drawn.
    ///
    /// The legend has no words of its own — it prints the series keys — so a
    /// legend that names models rather than reciting `claude-opus-4-8` is a
    /// matter of plotting the display name. An explicit domain is also what
    /// makes the range meaningful: without it Swift Charts orders the colours
    /// itself and a model can change colour between two periods.
    ///
    /// Two identifiers can share a name — a dated build and its undated model —
    /// and they already share a colour, so the later one folds into the earlier
    /// rather than putting "Haiku 4.5" in the legend twice.
    static func chartStyleScale(for slices: [DayModelSlice]) -> ChartStyleScale {
        var seen: Set<String> = []
        var scale = ChartStyleScale(domain: [], range: [])
        for slice in slices {
            let name = modelDisplayName(slice.model)
            guard seen.insert(name).inserted else { continue }
            scale.domain.append(name)
            scale.range.append(modelColor(slice.model))
        }
        return scale
    }

    // MARK: - The daily chart's x axis

    /// The instant one day after `day`, which is where that day's bar ends.
    ///
    /// A `BarMark` plotted with `unit: .day` is not a tick at `day`: it fills
    /// the whole bin `[day, day + 1)` and so is drawn *forward* from its own x
    /// value. Every alignment question the chart has — where the label goes,
    /// which bar a tap landed in — is a question about this span.
    static func barEnd(of day: Date, calendar: Calendar = LocalUsagePeriod.utcCalendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(24 * 60 * 60)
    }

    /// The middle of a day's bar, which is the one point the bar, its axis label
    /// and its tap target all have to agree on.
    static func barCentre(of day: Date, calendar: Calendar = LocalUsagePeriod.utcCalendar) -> Date {
        day.addingTimeInterval(barEnd(of: day, calendar: calendar).timeIntervalSince(day) / 2)
    }

    /// At most `desiredCount` of the series' days, evenly spread, always
    /// including the last one.
    ///
    /// The axis is labelled from the days the series actually has rather than
    /// from `.automatic` marks on the continuous scale, because an automatic
    /// mark falls on a round date that is nobody's bar centre. Counted back from
    /// the newest day so that the bar a reader looks at first is always named.
    static func axisDays(for days: [Date], desiredCount: Int) -> [Date] {
        guard desiredCount > 0 else { return [] }
        guard days.count > desiredCount else { return days }
        let step = Int((Double(days.count) / Double(desiredCount)).rounded(.up))
        let picked = Swift.stride(from: days.count - 1, through: 0, by: -step).map { days[$0] }
        return picked.reversed()
    }

    /// The day whose bar contains `value`, a date read off the chart's
    /// continuous x scale.
    ///
    /// `ChartProxy.value(atX:)` answers in scale units, so a tap in the visual
    /// middle of a bar comes back as roughly *noon* of that day, not its
    /// midnight. Snapping that raw value to the nearest day start therefore
    /// hands everything past a bar's middle to the following day — the whole hit
    /// map sits half a bar to the left of what the reader is aiming at. Asking
    /// which bin contains the value has no such offset.
    ///
    /// A value in a gutter or in a gap in the series belongs to no bin at all,
    /// and falls back to the day whose bar centre is nearest.
    static func day(
        atChartValue value: Date,
        among days: [Date],
        calendar: Calendar = LocalUsagePeriod.utcCalendar
    ) -> Date? {
        guard !days.isEmpty else { return nil }
        if let containing = days.first(where: {
            value >= $0 && value < barEnd(of: $0, calendar: calendar)
        }) {
            return containing
        }
        return days.min {
            let first = abs(barCentre(of: $0, calendar: calendar).timeIntervalSince(value))
            let second = abs(barCentre(of: $1, calendar: calendar).timeIntervalSince(value))
            return first < second
        }
    }

    // MARK: - Naming a day

    /// A day's name, spelled out: "Sunday, 15 March".
    ///
    /// Formatted in the calendar the day was *computed* in. Every day in the
    /// daily pipeline is a UTC midnight — that is what `LocalUsagePeriod
    /// .utcCalendar` is for, because grouping locally slices a day and drops
    /// part of it. Handing such an instant to a formatter reading the local
    /// timezone undoes that: west of Greenwich a UTC midnight is still the
    /// previous evening, so the panel named the day before the one whose figures
    /// it was showing.
    static func dayTitle(
        of day: Date,
        calendar: Calendar = LocalUsagePeriod.utcCalendar
    ) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    /// A day's name as the chart's x axis has room for it: "15 Mar".
    ///
    /// Same rule and the same reason as `dayTitle`. The axis labels bar
    /// *centres* — noon UTC — which survives a local formatter for most of the
    /// world and stops doing so from UTC+12 eastward, where noon UTC has already
    /// become the next day. A label that is right in Berlin and wrong in
    /// Auckland is the same bug, just harder to see.
    static func axisDayLabel(
        of day: Date,
        calendar: Calendar = LocalUsagePeriod.utcCalendar
    ) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    // MARK: - Naming a window inside its account's card

    /// How a window is labelled inside the card of the account it belongs to.
    ///
    /// The account switcher that used to make "whose window is this" obvious is
    /// gone, and the answer now sits in the card's own header — one card per
    /// account, its name at the top. That leaves each window inside needing only
    /// to say *which* window it is, which is why the account no longer appears
    /// here.
    ///
    /// Spelled out rather than reusing `QuotaIndicator`'s "5h" / "Week". Those
    /// are sized for a menu bar row a few points wide; a card has the room to say
    /// what it means, and a label that reads as a sentence fragment is what makes
    /// two stacked windows legible as two windows.
    static func quotaWindowLabel(for kind: RateWindowKind) -> String {
        switch kind {
        case .rollingFiveHours: "5-hour"
        case .weekly: "Weekly"
        case .billingCycle: "Billing cycle"
        }
    }

    // MARK: - Wording

    /// Why the figures below the Quotas section cannot be split per subscription.
    /// Stated on the screen, not just in a comment: an unqualified total invites
    /// the reader to attribute it to whichever subscription they had in mind.
    static let subscriptionScopeNote = """
        These figures cover every Claude subscription together. \
        The transcripts carry no marker of which subscription paid for a session, \
        so they cannot be attributed to one.
        """

    static let unpricedTotalNote =
        "At least one model has no price on file, so the total is incomplete."

    /// `ModelMix` computes each share against the *priced* spend. With an
    /// unpriced model in the period, "42 % of spend" silently means "42 % of what
    /// we could price", which is exactly the kind of quiet qualifier this app
    /// exists to say out loud.
    static let unpricedShareNote =
        "Shares are of the priced spend only — at least one model has no price on file."

    /// The quota windows report a consumed *fraction* and nothing else. There is
    /// no token cap in `RateWindow`, so the cards say percentages and pace and
    /// never invent an absolute figure to sit beside them.
    static let quotaNoCapNote =
        "Your subscription reports how much of a window is used, not a token cap, so these are percentages."

    static let unpricedLabel = "No price on file"

    /// Nil micros means the model is absent from the pricing catalog. It is
    /// rendered as unpriced and never as zero, which would read as "free".
    ///
    /// Numerals follow the system locale, as everywhere else in this app.
    static func amount(micros: Int64?, currency: String?) -> String {
        guard let micros else { return unpricedLabel }

        let value = Decimal(micros) / 1_000_000
        guard let currency else {
            return value.formatted(.number.precision(.fractionLength(2)))
        }

        return value.formatted(.currency(code: currency))
    }
}

private extension Color {
    /// A colour from the design's own `#rrggbb`, in sRGB.
    ///
    /// The palette is specified as hex in the reference, so it is written here as
    /// hex too: translating six digits into three fractions by hand at each entry
    /// is how a swatch silently drifts from the design it was copied out of.
    init(rgbHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}
