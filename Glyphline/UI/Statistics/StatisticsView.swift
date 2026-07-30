import SwiftUI

/// Machine-wide local token usage, per model, with what the API would have
/// billed for it.
///
/// Two things this screen must never be allowed to imply, and says outright:
/// the money was never charged — a subscription is a flat fee — and the figures
/// are the sum across every subscription, because the transcripts carry no
/// marker of which one paid for a session.
struct StatisticsView: View {
    @EnvironmentObject private var coordinator: SyncCoordinator

    @State private var period: LocalUsagePeriod = .last30Days
    @State private var statistics: LocalUsageStatistics?

    /// Why the figures cannot be split per subscription. Stated on the screen,
    /// not just in a comment: an unqualified total invites the reader to
    /// attribute it to whichever subscription they had in mind.
    static let subscriptionScopeNote = """
        These figures cover every Claude subscription together. \
        The transcripts carry no marker of which subscription paid for a session, \
        so they cannot be attributed to one.
        """

    static let unpricedTotalNote =
        "At least one model has no price on file, so the total is incomplete."

    private static let unpricedLabel = "No price on file"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                periodPicker
                body(for: statistics)
                notes
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Keyed on the period and on the scan revision, so the aggregate is
        // recomputed when either changes and not on every render pass — the
        // computation reads the ledger.
        .task(id: ReloadKey(period: period, revision: coordinator.localUsageRevision)) {
            statistics = coordinator.localUsageStatistics(since: period.since(now: Date()))
        }
    }

    private struct ReloadKey: Equatable {
        var period: LocalUsagePeriod
        var revision: Int
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Local Token Usage")
                    .font(.largeTitle.weight(.bold))
                Spacer()
                Button {
                    Task { await coordinator.scanLocalUsage() }
                } label: {
                    Label("Scan Now", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.isScanningLocalUsage)
            }

            Text("Tokens read from your Claude Code transcripts on this Mac.")
                .foregroundStyle(.secondary)

            if let message = coordinator.localScanFailureMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(LocalUsagePeriod.allCases) { period in
                Text(period.title).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360, alignment: .leading)
    }

    @ViewBuilder private func body(for statistics: LocalUsageStatistics?) -> some View {
        if coordinator.isScanningLocalUsage, statistics?.models.isEmpty ?? true {
            // A scan of the reference machine reads gigabytes. An empty table
            // here would read as "you have used nothing".
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning local transcripts…")
                    .foregroundStyle(.secondary)
            }
        } else if let statistics, !statistics.models.isEmpty {
            table(statistics)
        } else if statistics == nil {
            Text("Ledger unavailable.")
                .foregroundStyle(.secondary)
        } else {
            Text("No local token usage recorded for this period.")
                .foregroundStyle(.secondary)
        }
    }

    private func table(_ statistics: LocalUsageStatistics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if coordinator.isScanningLocalUsage {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning local transcripts…")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 10)
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("Model")
                    Text("Tokens")
                        .gridColumnAlignment(.trailing)
                    Text("API-Equivalent Value")
                        .gridColumnAlignment(.trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()
                    .gridCellUnsizedAxes(.horizontal)

                ForEach(statistics.models) { model in
                    GridRow {
                        Text(model.model ?? "Unknown model")
                        Text(model.totalTokens.formatted())
                            .monospacedDigit()
                        Text(Self.amount(micros: model.estimatedAmountMicros, currency: model.currency))
                            .monospacedDigit()
                            .foregroundStyle(model.isUnpriced ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    }
                }

                Divider()
                    .gridCellUnsizedAxes(.horizontal)

                GridRow {
                    Text("Total")
                    Text(statistics.totalTokens.formatted())
                        .monospacedDigit()
                    Text(Self.amount(
                        micros: statistics.estimatedAmountMicros,
                        currency: statistics.currency
                    ))
                    .monospacedDigit()
                }
                .font(.body.weight(.semibold))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            if statistics.hasUnpricedModels {
                Text(Self.unpricedTotalNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalUsageStatistics.estimateDisclaimer)
            Text(Self.subscriptionScopeNote)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Formatting

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
