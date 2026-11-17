import Foundation

/// One API organisation's credit, as the account's card shows it.
///
/// Identified by the organisation id, never shown: organisation names are not
/// decoded at all, so several organisations on one account are numbered.
struct ConsoleCreditCardModel: Identifiable, Equatable {
    var id: String
    var title: String
    var balanceText: String?
    var expiryText: String?
    var expiryIsUrgent: Bool
    var spendText: String?
    var message: String?

    /// - Parameters:
    ///   - position: 1-based, in stored order.
    ///   - count: how many organisations the account has; the title is numbered
    ///     only when there is more than one.
    static func make(
        _ state: ConsoleCreditState,
        position: Int,
        of count: Int,
        now: Date,
        locale: Locale = .current
    ) -> ConsoleCreditCardModel {
        let title = count == 1
            ? String(localized: "API credit", comment: "Heading of the Claude Console prepaid-credit block on an account card.")
            : String(
                localized: "API credit \(position)",
                comment: "Heading of a Claude Console prepaid-credit block when an account has several API organisations. The placeholder is its 1-based number."
            )

        var model = ConsoleCreditCardModel(
            id: state.organization.id,
            title: title,
            balanceText: nil,
            expiryText: nil,
            expiryIsUrgent: false,
            spendText: nil,
            // A failure keeps the last balance beside it rather than replacing it.
            message: state.failure?.consoleMessage
        )

        guard let balance = state.balance else { return model }

        func amount(_ minor: Int64) -> String {
            ConsoleCreditFormatting.amount(minor, exponent: balance.exponent, currency: balance.currency, locale: locale)
        }

        let balanceAmount = amount(balance.balanceMinor)
        model.balanceText = String(
            localized: "\(balanceAmount) left",
            comment: "Claude Console prepaid credit remaining. The placeholder is a currency amount."
        )

        if let expiry = balance.nextExpiry {
            let expiryAmount = amount(expiry.amountMinor)
            let date = expiry.at.formatted(
                Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).locale(locale)
            )
            let remaining = expiry.at.timeIntervalSince(now)
            let duration = QuotaIndicator.compactDuration(remaining)
            model.expiryText = String(
                localized: "\(expiryAmount) expires \(date) (in \(duration))",
                comment: "Claude Console credit that lapses next. Placeholders: a currency amount, a short date such as 'Sat 29 Nov', a compact duration such as '4d 6h'."
            )
            model.expiryIsUrgent = remaining > 0 && remaining <= ConsoleCreditRule.urgentExpiry
        }

        if let spend = balance.monthSpendMinor {
            let spendAmount = amount(spend)
            model.spendText = String(
                localized: "\(spendAmount) spent this month",
                comment: "Claude Console API spend in the current month. The placeholder is a currency amount."
            )
        }

        return model
    }
}
