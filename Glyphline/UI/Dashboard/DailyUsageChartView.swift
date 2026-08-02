import Charts
import SwiftUI

/// The chart's period switcher.
///
/// Its own view so it can be laid out and measured on its own, which is the only
/// way to hold what it is here for: a segmented control given less width than it
/// asks for truncates its segments, silently, in whatever language happens to be
/// longest. It used to be pinned at `.frame(width: 220)`, measured once against
/// "7 Days / 30 Days / All Time" — which itself wants 221, so English was already
/// short by a point — while Italian's "7 giorni / 30 giorni / Tutto" wants 234.
/// `.fixedSize()` asks for what the words need instead, and the card has it to
/// give: this row is a title and this picker inside a pane at least 980 points
/// wide.
struct ChartPeriodPicker: View {
    @Binding var period: LocalUsagePeriod

    /// What each segment is called. The periods' own names by default; the
    /// measurement tests hand in another language's, because those names come
    /// from `String(localized:)` and so follow the language of the *process* —
    /// which the test scheme pins to English — rather than a locale a test could
    /// put in the environment.
    var title: (LocalUsagePeriod) -> String = \.title

    var body: some View {
        Picker("Period", selection: $period) {
            ForEach(LocalUsagePeriod.allCases) { period in
                Text(verbatim: title(period)).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - The chart

struct DailyUsageChart: View {
    let entries: [DailyUsageEntry]
    let legendLimit: Int
    let mix: ModelMix?
    @Binding var selectedDay: Date?

    private static let plotHeight: CGFloat = 190

    var body: some View {
        if entries.isEmpty {
            EmptyStateBox("No local token usage recorded for this period.")
                .frame(height: Self.plotHeight)
        } else if entries.count == 1 {
            // One day is not a trend, and a single bar on a 30-day axis invites
            // the reader to see one. Say what there is instead.
            EmptyStateBox("""
                Only one day of usage has been recorded so far. \
                The chart starts telling you something once there are a few.
                """)
                .frame(height: Self.plotHeight)
        } else {
            chart
        }
    }

    private var slices: [DashboardPresentation.DayModelSlice] {
        let models = mix.map { DashboardPresentation.chartModels(from: $0, limit: legendLimit) } ?? []
        return DashboardPresentation.slices(for: entries, keeping: models)
    }

    /// The day the detail panel is describing: the tapped one, or the last day
    /// when nothing has been tapped yet.
    private var highlightedDay: Date? {
        selectedDay ?? entries.last?.day
    }

    private var chart: some View {
        let slices = self.slices
        let scale = DashboardPresentation.chartStyleScale(for: slices)
        let highlighted = highlightedDay

        return Chart(slices) { slice in
            BarMark(
                x: .value("Day", slice.day, unit: .day),
                y: .value("Tokens", slice.tokens)
            )
            // The series key is the legend's text, so it is the model's name and
            // not its identifier. Nobody reads a bill in `claude-opus-4-8`.
            .foregroundStyle(by: .value("Model", DashboardPresentation.modelDisplayName(slice.model)))
            // The unselected days are dimmed rather than the selected one
            // brightened: the palette is already saturated, and lightening a
            // pink or a purple towards white costs exactly the generation
            // difference the scheme encodes. Opacity only — a bar's geometry
            // must not move when the selection does.
            .opacity(highlighted == nil || slice.day == highlighted ? 1 : 0.55)
        }
        // The chart's colours are the app's, not Swift Charts' defaults: the
        // hue names the model family everywhere it appears.
        .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        // Marked at bar centres, not at bar starts. A `unit: .day` bar is drawn
        // forward from its own date, so a mark at that date labels the bar's
        // leading edge and the reader reads every label one half-bar too far
        // left. The centre is noon of the same day, so it still formats as that
        // day.
        .chartXAxis {
            AxisMarks(values: Self.axisMarks(for: entries)) { value in
                AxisGridLine()
                if let day = value.as(Date.self) {
                    AxisValueLabel(DashboardPresentation.axisDayLabel(of: day))
                }
            }
        }
        // The days are UTC day starts (see `DailyUsageSeries`). Charts would bin
        // them by the local calendar instead, putting every bar a timezone
        // offset away from the day it stands for — and away from the marks and
        // the hit test below, which reason in the same UTC days the data has.
        .environment(\.calendar, LocalUsagePeriod.utcCalendar)
        .frame(height: Self.plotHeight)
        // The band is drawn in the chart's *background*, so it sits behind the
        // bars instead of veiling them. The tap target stays an overlay,
        // because a background cannot receive the gesture.
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    selectionBand(rect: geometry[plotFrame], proxy: proxy)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let rect = geometry[plotFrame]
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            select(at: location.x - rect.minX, proxy: proxy)
                        }
                }
            }
        }
    }

    /// The selected column's soft, borderless band, full plot height.
    ///
    /// The stroked box this replaces was taller than its bar and so framed a
    /// column of empty air, with a corner radius that matched nothing else on
    /// the page — it read as a stray container rather than as a selection. A
    /// band behind the column is the bar chart's own idiom: it says "this
    /// column" without drawing an edge anywhere the data has none.
    ///
    /// It is laid out from the plot rect and the day's own x positions, so
    /// moving the selection changes neither the bars' widths nor anything's
    /// position.
    @ViewBuilder private func selectionBand(rect: CGRect, proxy: ChartProxy) -> some View {
        if let day = highlightedDay,
           let start = proxy.position(forX: day),
           let end = proxy.position(forX: DashboardPresentation.barEnd(of: day)) {
            let width = max(end - start, 3)
            Rectangle()
                .fill(.primary.opacity(0.09))
                .frame(width: width, height: rect.height)
                .position(x: rect.minX + start + width / 2, y: rect.minY + rect.height / 2)
                .allowsHitTesting(false)
        }
    }

    /// Where the axis is labelled: at most six of the series' own days, each
    /// moved to its bar's centre.
    private static func axisMarks(for entries: [DailyUsageEntry]) -> [Date] {
        DashboardPresentation
            .axisDays(for: entries.map(\.day), desiredCount: 6)
            .map { DashboardPresentation.barCentre(of: $0) }
    }

    /// Selects the bar the tap landed in, snapping to the nearest bar when it
    /// landed in a gutter. The mapping lives in `DashboardPresentation` because
    /// it is the half-bar offset this chart used to get wrong, and it is worth a
    /// test that a closure in here cannot have.
    private func select(at x: CGFloat, proxy: ChartProxy) {
        guard let tapped: Date = proxy.value(atX: x) else { return }
        if let day = DashboardPresentation.day(atChartValue: tapped, among: entries.map(\.day)) {
            selectedDay = day
        }
    }
}

// MARK: - The day detail

/// The day beneath the legend.
///
/// It costs no height: the card was already this tall and the space under the
/// legend was empty. The frame is fixed for that reason — a day with more models
/// than fit has its list cut rather than the card grown.
struct DayDetailPanel: View {
    let entry: DailyUsageEntry?
    let isToday: Bool

    /// As many rows as the space that was already there holds, in two columns.
    private static let rowLimit = 6
    private static let height: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            if let entry {
                head(entry)
                rows(entry)
            } else {
                Text("Pick a day in the chart to see which models ran on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(height: Self.height, alignment: .top)
        .clipped()
    }

    private func head(_ entry: DailyUsageEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(DashboardPresentation.dayTitle(of: entry.day))
                .font(.callout.weight(.semibold))
            if isToday {
                Text("today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("""
                \(entry.totalTokens.formatted()) tokens · \
                \(DashboardPresentation.amount(
                    micros: entry.estimatedAmountMicros,
                    currency: entry.currency
                ))
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder private func rows(_ entry: DailyUsageEntry) -> some View {
        if entry.isEmpty {
            // A day with no rows is a zero day, not a missing one. Saying so is
            // the difference between "you did not work" and "we lost the data".
            Text("Nothing was recorded on this day.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            // Ranked by volume, as the reference has it: this panel answers
            // "what ran", where the mix card answers "what cost".
            let ranked = Array(
                entry.statistics.models
                    .sorted { $0.totalTokens > $1.totalTokens }
                    .prefix(Self.rowLimit)
            )
            let peak = ranked.first?.totalTokens ?? 0

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)],
                alignment: .leading,
                spacing: 5
            ) {
                ForEach(ranked) { model in
                    HStack(spacing: 8) {
                        ModelSwatch(identifier: model.model)
                        Text(model.model.map(DashboardPresentation.modelDisplayName)
                            ?? DashboardPresentation.unknownModelLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        ProportionBar(
                            fraction: peak > 0 ? Double(model.totalTokens) / Double(peak) : 0
                        )
                        Text(model.totalTokens.formatted())
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }
}

private struct ProportionBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(width: 46, height: 4)
    }
}
