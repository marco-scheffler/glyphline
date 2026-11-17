import SwiftUI

/// One API organisation's credit block, shared by the dashboard card and the
/// Accounts list so both say the same thing the same way.
struct ConsoleCreditBlock: View {
    let model: ConsoleCreditCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardTitle(model.title)
                .lineLimit(1)

            if let balanceText = model.balanceText {
                Text(balanceText)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    // A failed reading keeps the last balance, greyed out.
                    .foregroundStyle(model.message == nil ? .primary : .secondary)
            }

            if let expiryText = model.expiryText {
                Text(expiryText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(model.expiryIsUrgent ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }

            if let spendText = model.spendText {
                Text(spendText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
