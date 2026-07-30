import SwiftUI

/// One quota window, rendered the same way wherever it appears.
///
/// Shared by the account card and the menu bar panel deliberately: the two
/// surfaces already draw from one accessor, and a second copy of the layout is
/// how "Cycle ends" becomes "Cycle resets" in one place only.
struct QuotaBarRowView: View {
    /// How the row arranges itself. Not a cosmetic preference: the wide form
    /// spends a fixed 52pt on the label plus a fixed bar width, which leaves the
    /// 320pt menu bar panel too little room for a detail string such as
    /// "17% — resets 04.08.26, 0:59" and squeezes the bar to make it fit.
    enum Layout {
        /// One line — label, bar, detail, optional as-of. For the dashboard card,
        /// which has the width to spare.
        case wide
        /// Two lines — label and detail on the first, the bar spanning the full
        /// width beneath. Cannot overflow at any container width, and gives the
        /// bar more pixels than the wide form manages in a narrow panel.
        case compact
    }

    let row: QuotaBarRow
    var layout: Layout = .wide
    /// Consulted by `.wide` only; the compact form lets the bar span whatever
    /// width its container offers.
    var barWidth: CGFloat = 160

    var body: some View {
        switch layout {
        case .wide:
            wideBody
        case .compact:
            compactBody
        }
    }

    private var wideBody: some View {
        HStack(spacing: 10) {
            Text(row.label)
                .font(.callout.weight(.medium))
                .frame(width: 52, alignment: .leading)

            bar
                .frame(maxWidth: barWidth)

            // Monospaced digits: percentages and remaining times change every
            // poll, and proportional figures make the whole line shift sideways
            // as they do.
            Text(row.detail)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            if let asOf = row.asOf {
                asOfCaption(asOf)
                    .font(.caption)
            }
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A `Spacer` rather than a fixed label width: label left, detail
            // right, using the full width the panel gives us instead of a gutter
            // sized for a wider surface.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.label)
                    .font(.caption.weight(.medium))

                Spacer(minLength: 8)

                Text(row.detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            bar

            // Beneath the bar rather than appended to the first line: the detail
            // string already claims the right-hand side of that line, and adding
            // the caption to it is exactly what makes the row wrap.
            if let asOf = row.asOf {
                asOfCaption(asOf)
                    .font(.caption2)
            }
        }
    }

    /// `fraction ?? 0` only ever reaches a bar dimmed to near invisibility: a
    /// missing figure must not read as an empty quota.
    private var bar: some View {
        ProgressView(value: row.fraction ?? 0)
            .progressViewStyle(.linear)
            .tint(tint)
            .opacity(row.fraction == nil ? 0.25 : 1)
    }

    /// The verdict is `QuotaIndicator`'s; this only picks the paint. `nil` leaves
    /// the accent tint alone on a bar that is already dimmed to near invisibility
    /// — an unknown figure gets no colour, because colour here means a number.
    private var tint: Color? {
        switch row.severity {
        case .normal: .green
        case .warning: .orange
        case .exhausted: .red
        case .unknown: nil
        }
    }

    private func asOfCaption(_ asOf: Date) -> some View {
        Text("(as of \(asOf.formatted(date: .omitted, time: .shortened)))")
            .foregroundStyle(.tertiary)
    }
}
