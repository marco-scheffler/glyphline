import SwiftUI

/// Says that a one-time rebuild changed recorded figures, until dismissed.
///
/// Without it a user who skipped the release notes sees a step in their
/// charts with no explanation anywhere in the app.
///
/// Takes the date and the dismissal as parameters rather than reading
/// `AppSettingsStore` from the environment: the overview is also hosted
/// without one, and an environment read there would trap.
struct RecalculatedHistoryNotice: View {
    let date: Date?
    let dismiss: () -> Void

    var body: some View {
        if let date {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(
                    String(
                        localized: "Your usage history was recalculated on \(date.formatted(.dateTime.day().month(.abbreviated))). Earlier figures may differ from what you saw before.",
                        comment: "Dashboard notice after a one-time rebuild changed recorded usage. The placeholder is a short date such as '12 Oct'."
                    ),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                Spacer()
                Button("Dismiss") { dismiss() }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }
}
