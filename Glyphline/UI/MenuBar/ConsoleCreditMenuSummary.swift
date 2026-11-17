import Foundation

/// An account's Console credit, small enough to sit on the same line as the
/// account's name in the menu bar panel.
///
/// The panel is a glance, not the card: one figure, and — only when credit is
/// about to lapse — how soon. Nothing that would need a line of its own, so the
/// panel does not grow for an account that has the Console connected.
struct ConsoleCreditMenuSummary: Equatable {
    /// "API $157.14".
    var balanceText: String
    /// How soon credit lapses, as a compact duration — only within
    /// `ConsoleCreditRule.urgentExpiry`; further out it is the card's business.
    var expiryText: String?
    /// The full sentence a figure and a bare duration stand for.
    var accessibilityText: String

    /// `nil` when no organisation has a balance yet: a "Checking…" or a failure
    /// is said on the card, and saying it here as well would cost the line.
    ///
    /// Several organisations are added up only when they share a currency; a
    /// sum across currencies is not a number. Otherwise the first organisation
    /// with a balance speaks for the account.
    static func make(
        _ states: [ConsoleCreditState],
        now: Date,
        locale: Locale = .current
    ) -> ConsoleCreditMenuSummary? {
        let balances = states.compactMap(\.balance)
        guard let first = balances.first else { return nil }

        let sameUnit = balances.allSatisfy { $0.currency == first.currency && $0.exponent == first.exponent }
        let counted = sameUnit ? balances : [first]

        var total: Int64 = 0
        for balance in counted {
            let (sum, overflow) = total.addingReportingOverflow(balance.balanceMinor)
            guard !overflow else { return nil }
            total = sum
        }

        func amount(_ minor: Int64) -> String {
            ConsoleCreditFormatting.amount(minor, exponent: first.exponent, currency: first.currency, locale: locale)
        }

        let totalAmount = amount(total)
        let balanceText = String(
            localized: "API \(totalAmount)",
            comment: "Claude Console credit beside an account's name in the menu bar panel. The placeholder is a currency amount; keep it short."
        )
        var accessibilityText = String(localized: "API credit") + ", " + String(localized: "\(totalAmount) left")

        let soonest = counted
            .compactMap(\.nextExpiry)
            .filter { $0.at > now && $0.at.timeIntervalSince(now) <= ConsoleCreditRule.urgentExpiry }
            .min { $0.at < $1.at }

        var expiryText: String?
        if let soonest {
            let duration = QuotaIndicator.compactDuration(soonest.at.timeIntervalSince(now))
            expiryText = duration
            let lapsing = amount(soonest.amountMinor)
            accessibilityText += ", " + String(localized: "\(lapsing) of API credit expires in \(duration)")
        }

        return ConsoleCreditMenuSummary(
            balanceText: balanceText,
            expiryText: expiryText,
            accessibilityText: accessibilityText
        )
    }
}
