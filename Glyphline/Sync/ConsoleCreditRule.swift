import Foundation

/// When a Console credit balance deserves the user's attention. Pure, so the
/// thresholds are tested apart from WebKit and notifications.
enum ConsoleCreditRule {
    /// A tranche lapsing within this window is announced.
    static let expiryNotice: TimeInterval = 3 * 86_400
    /// Within this window the expiry line is drawn as urgent.
    static let urgentExpiry: TimeInterval = 7 * 86_400

    /// Identifies one expiry event, so it is announced once.
    struct ExpiryKey: Hashable {
        let accountID: UUID
        let organizationID: String
        let expiresAt: Date
    }

    /// The balance's next expiry when it lies in the future and within
    /// `expiryNotice`; `nextExpiry` is already limited to live tranches.
    static func expiringSoon(_ balance: ConsoleCreditBalance, now: Date) -> ConsoleCreditBalance.Expiry? {
        guard let expiry = balance.nextExpiry else { return nil }
        let remaining = expiry.at.timeIntervalSince(now)
        guard remaining > 0, remaining <= expiryNotice else { return nil }
        return expiry
    }

    static func isLow(_ balance: ConsoleCreditBalance) -> Bool {
        balance.balanceMinor < balance.lowBalanceThresholdMinor
    }
}
