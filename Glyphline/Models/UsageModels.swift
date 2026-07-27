import Foundation

enum DataQuality: String, Codable, Sendable {
    case exact
    case estimated
    case partial
    case unavailable

    func isBetterThan(_ other: DataQuality) -> Bool {
        rank < other.rank
    }

    private var rank: Int {
        switch self {
        case .exact:
            0
        case .estimated:
            1
        case .partial:
            2
        case .unavailable:
            3
        }
    }
}

struct BillingPeriod: Codable, Equatable, Sendable {
    var startsAt: Date
    var endsAt: Date?
    var resetAt: Date?
}

struct UsageSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var accountID: UUID
    var providerID: ProviderID
    var bucketStart: Date
    var bucketEnd: Date
    var model: String?
    var inputTokens: Int64
    var outputTokens: Int64
    var requests: Int64
    var quality: DataQuality
}

struct CostSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var accountID: UUID
    var providerID: ProviderID
    var bucketStart: Date
    var bucketEnd: Date
    var amountMicros: Int64
    var currency: String
    var quality: DataQuality
}

struct EstimateSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var accountID: UUID
    var providerID: ProviderID
    var bucketStart: Date
    var bucketEnd: Date
    var estimatedAmountMicros: Int64
    var currency: String
    var quality: DataQuality
}
