import SwiftUI

struct HistorySummaryEntry: Identifiable, Equatable {
    let accountName: String?
    let summary: DailyUsageSummary

    var id: String {
        summary.id
    }
}

struct HistoryView: View {
    let entries: [HistorySummaryEntry]

    init(summaries: [DailyUsageSummary]) {
        self.entries = summaries.map { HistorySummaryEntry(accountName: nil, summary: $0) }
    }

    init(entries: [HistorySummaryEntry]) {
        self.entries = entries
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Sync an account to start building local usage history over time.")
                )
            } else {
                List(entries, id: \.id) { entry in
                    HistorySummaryRow(entry: entry)
                        .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("History")
    }
}

struct HistorySummaryRow: View {
    let entry: HistorySummaryEntry
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                Text(entry.summary.dayStart, format: .dateTime.month(.abbreviated).day().year())
                    .font(compact ? .subheadline.weight(.semibold) : .headline)

                if let accountName = entry.accountName {
                    Text(accountName)
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(detailSummary)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: compact ? 6 : 8) {
                DataQualityBadge(quality: entry.summary.quality)

                Text(tokenSummary)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .monospacedDigit()

                if let costSummary {
                    Text(costSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var detailSummary: String {
        AccountSummaryFormatting.requests(entry.summary.requests)
    }

    private var tokenSummary: String {
        AccountSummaryFormatting.tokens(entry.summary.totalTokens)
    }

    private var costSummary: String? {
        guard
            let estimatedAmountMicros = entry.summary.estimatedAmountMicros,
            let currency = entry.summary.currency
        else {
            return nil
        }

        let amount = Decimal(estimatedAmountMicros) / 1_000_000
        return "\(currency) \(amount.formatted(.number.precision(.fractionLength(2))))"
    }
}
