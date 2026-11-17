import Foundation

/// An API organisation on platform.claude.com. Only the id is kept: the name
/// carries the user's email address and is never decoded, for the same reason
/// `ClaudeOrganization` gives.
struct ConsoleOrganization: Codable, Equatable, Sendable {
    var id: String
}

/// Picks the API organisations out of `GET https://platform.claude.com/api/organizations`.
///
/// The platform returns the same entries as claude.ai, so `ClaudeOrganization`
/// decodes them. The Max subscription is in the same list and has no credit
/// balance, so selection is by capability, never by position.
enum ConsoleOrganizationsResponse {
    static let apiCapability = "api"

    static func apiOrganizations(from data: Data) throws -> [ConsoleOrganization] {
        try ClaudeOrganizationsResponse.decode(data)
            .filter { $0.capabilities.contains(apiCapability) }
            .map { ConsoleOrganization(id: $0.uuid) }
    }
}

/// Decodes `…/organizations/{org}/prepaid/credits`.
///
/// This is the Console's own web API, not a published one, so every field is
/// read on its own and one odd value never fails its neighbours. Only the
/// absence of any balance makes the response useless, and that is decided by
/// `ConsoleCreditBalance`, not here.
struct ConsoleCreditsResponse: Decodable {
    /// One grant of credit. Purchased and promotional tranches are read alike:
    /// both lapse, and the expiry line only cares when and how much.
    struct Tranche: Decodable, Equatable, Sendable {
        var remainingMinor: Int64?
        var expiresAt: Date?

        private enum CodingKeys: String, CodingKey {
            case remainingMinor = "remaining_amount_minor_units"
            case expiresAt = "expires_at"
        }

        init(remainingMinor: Int64?, expiresAt: Date?) {
            self.remainingMinor = remainingMinor
            self.expiresAt = expiresAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            remainingMinor = (try? container.decodeIfPresent(Int64.self, forKey: .remainingMinor)) ?? nil
            expiresAt = (try? container.decodeIfPresent(Date.self, forKey: .expiresAt)) ?? nil
        }
    }

    var balanceMinor: Int64?
    var exponent: Int
    var currency: String
    var tranches: [Tranche]

    private enum CodingKeys: String, CodingKey {
        case amount
        case currency
        case balance
        case tranches
        case promoTranches = "promo_tranches"
    }

    private enum BalanceKeys: String, CodingKey { case credits }
    private enum CreditsKeys: String, CodingKey {
        case amountMinor = "amount_minor"
        case exponent
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A currency is required: an amount without one cannot be shown honestly.
        currency = try container.decode(String.self, forKey: .currency)

        // `balance.credits` states its own exponent and is preferred. The
        // top-level `amount` is the older field and is in cents.
        let balance = try? container.nestedContainer(keyedBy: BalanceKeys.self, forKey: .balance)
        let credits = try? balance?.nestedContainer(keyedBy: CreditsKeys.self, forKey: .credits)
        let creditsMinor = (try? credits?.decodeIfPresent(Int64.self, forKey: .amountMinor)) ?? nil
        let creditsExponent = (try? credits?.decodeIfPresent(Int.self, forKey: .exponent)) ?? nil
        if let creditsMinor, let creditsExponent {
            balanceMinor = creditsMinor
            exponent = creditsExponent
        } else {
            balanceMinor = (try? container.decodeIfPresent(Int64.self, forKey: .amount)) ?? nil
            exponent = 2
        }

        let purchased = (try? container.decodeIfPresent([Tranche].self, forKey: .tranches)) ?? nil
        let promotional = (try? container.decodeIfPresent([Tranche].self, forKey: .promoTranches)) ?? nil
        tranches = (purchased ?? []) + (promotional ?? [])
    }

    static func decode(_ data: Data) throws -> ConsoleCreditsResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(ClaudeUsageResponse.decodeTimestamp)
        return try decoder.decode(ConsoleCreditsResponse.self, from: data)
    }
}

/// Decodes `…/organizations/{org}/current_spend`, in minor units of the org currency.
struct ConsoleCurrentSpendResponse: Decodable {
    var amountMinor: Int64?
    var resetsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case amountMinor = "amount"
        case resetsAt = "resets_at"
    }

    init(amountMinor: Int64?, resetsAt: Date?) {
        self.amountMinor = amountMinor
        self.resetsAt = resetsAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amountMinor = (try? container.decodeIfPresent(Int64.self, forKey: .amountMinor)) ?? nil
        resetsAt = (try? container.decodeIfPresent(Date.self, forKey: .resetsAt)) ?? nil
    }

    static func decode(_ data: Data) throws -> ConsoleCurrentSpendResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(ClaudeUsageResponse.decodeTimestamp)
        return try decoder.decode(ConsoleCurrentSpendResponse.self, from: data)
    }
}

/// What the account card shows about one API organisation's prepaid credit.
struct ConsoleCreditBalance: Equatable, Sendable {
    /// The next instant some credit lapses, and how much lapses then.
    struct Expiry: Equatable, Sendable {
        var at: Date
        var amountMinor: Int64
    }

    var currency: String
    var exponent: Int
    var balanceMinor: Int64
    var nextExpiry: Expiry?
    var monthSpendMinor: Int64?
}

extension ConsoleCreditBalance {
    /// Nil only when no balance is decodable; a missing spend or unreadable
    /// tranches still leave a balance worth showing.
    init?(credits: ConsoleCreditsResponse, spend: ConsoleCurrentSpendResponse?, now: Date) {
        // An exponent no Int64 amount can carry is not a balance; it is
        // rejected here rather than clamped into a wrong one.
        guard let balanceMinor = credits.balanceMinor,
              ConsoleCreditFormatting.powerOfTen(credits.exponent) != nil
        else { return nil }

        // A tranche that has already lapsed or has nothing left cannot lapse
        // again, so it would only produce a warning about nothing.
        let live = credits.tranches.compactMap { tranche -> (Date, Int64)? in
            guard let at = tranche.expiresAt, at > now,
                  let remaining = tranche.remainingMinor, remaining > 0
            else { return nil }
            return (at, remaining)
        }
        // Tranches lapsing on the same instant are one event, so they make one
        // line and one notification with their sum. A sum past Int64 is a
        // server value nobody can show honestly, so that expiry is dropped.
        let nextExpiry = live.map(\.0).min().flatMap { earliest -> Expiry? in
            var sum: Int64 = 0
            for (at, remaining) in live where at == earliest {
                let (next, overflow) = sum.addingReportingOverflow(remaining)
                if overflow { return nil }
                sum = next
            }
            return Expiry(at: earliest, amountMinor: sum)
        }

        self.init(
            currency: credits.currency,
            exponent: credits.exponent,
            balanceMinor: balanceMinor,
            nextExpiry: nextExpiry,
            monthSpendMinor: spend?.amountMinor
        )
    }

    /// Five major units of the balance's own currency, whatever its exponent.
    /// Nil when the exponent cannot be carried in Int64.
    var lowBalanceThresholdMinor: Int64? {
        guard let unit = ConsoleCreditFormatting.powerOfTen(exponent) else { return nil }
        let (threshold, overflow) = unit.multipliedReportingOverflow(by: 5)
        return overflow ? nil : threshold
    }
}

enum ConsoleCreditFormatting {
    /// Money is kept in minor units and only becomes a decimal here, so the
    /// currency symbol and digits always follow the reported currency.
    static func amount(_ minor: Int64, exponent: Int, currency: String, locale: Locale = .current) -> String {
        // A balance cannot carry an exponent `powerOfTen` rejects; 1 only keeps
        // a hand-built value from trapping.
        let divisor = Decimal(powerOfTen(exponent) ?? 1)
        return (Decimal(minor) / divisor).formatted(.currency(code: currency).locale(locale))
    }

    /// 10^exponent, or nil outside 0...18 — the range an Int64 can hold.
    static func powerOfTen(_ exponent: Int) -> Int64? {
        guard (0...18).contains(exponent) else { return nil }
        var result: Int64 = 1
        for _ in 0..<exponent { result *= 10 }
        return result
    }
}
