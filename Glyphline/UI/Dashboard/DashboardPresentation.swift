import Foundation

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

    /// How the header's Agentverse button reads and whether it is allowed to
    /// shout.
    ///
    /// `isUrgent` drives amber and a slow pulse, matching the plumbob over a
    /// waiting agent's head so both surfaces speak one language. With nobody
    /// waiting it goes quiet: a dashboard that always looks urgent stops meaning
    /// anything.
    struct AgentverseCallToAction: Equatable, Sendable {
        var waiting: Int
        var working: Int
        var resting: Int
        var headline: String
        var detail: String
        var isUrgent: Bool
        /// No sessions at all — neither waiting nor working nor parked. The
        /// button still opens the map, it simply says there is nobody in it.
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

        let detail = isEmpty
            ? "Open the Agentverse"
            : "\(working) working · \(resting) resting — open the Agentverse"

        return AgentverseCallToAction(
            waiting: waiting,
            working: working,
            resting: resting,
            headline: headline,
            detail: detail,
            isUrgent: waiting > 0,
            isEmpty: isEmpty
        )
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
