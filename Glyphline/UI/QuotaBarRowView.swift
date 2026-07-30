import SwiftUI

/// One quota window, rendered the same way wherever it appears.
///
/// Shared by the account card and the menu bar panel deliberately: the two
/// surfaces already draw from one accessor, and a second copy of the layout is
/// how "Cycle ends" becomes "Cycle resets" in one place only.
struct QuotaBarRowView: View {
    let row: QuotaBarRow
    var barWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 10) {
            Text(row.label)
                .font(.callout.weight(.medium))
                .frame(width: 52, alignment: .leading)

            // `fraction ?? 0` only ever reaches a bar that is dimmed to near
            // invisibility: a missing figure must not read as an empty quota.
            ProgressView(value: row.fraction ?? 0)
                .progressViewStyle(.linear)
                .frame(maxWidth: barWidth)
                .opacity(row.fraction == nil ? 0.25 : 1)

            Text(row.detail)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let asOf = row.asOf {
                Text("(as of \(asOf.formatted(date: .omitted, time: .shortened)))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
