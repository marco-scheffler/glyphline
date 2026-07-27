import SwiftUI

struct HistoryView: View {
    let entries: [PlaceholderHistoryEntry]

    var body: some View {
        List(entries) { entry in
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title)
                        .font(.headline)

                    Text(entry.accountName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(entry.detailSummary)
                        .font(.callout)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    DataQualityBadge(quality: entry.dataQuality)
                    Text(entry.occurredAtSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
        .navigationTitle("History")
    }
}
