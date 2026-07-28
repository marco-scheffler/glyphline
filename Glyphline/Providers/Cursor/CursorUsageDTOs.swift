import Foundation

struct CursorUsageEventsResponse: Decodable {
    var usageEvents: [CursorUsageEvent]
    var pagination: CursorPagination?
}

struct CursorPagination: Decodable {
    var currentPage: Int?
    var hasNextPage: Bool?
}

struct CursorUsageEvent: Decodable {
    /// Epoch milliseconds, delivered as a string.
    var timestamp: String
    var model: String?
    var isTokenBasedCall: Bool?
    /// Cents, with sub-cent precision.
    var chargedCents: Decimal?
    var tokenUsage: CursorTokenUsage?

    var date: Date? {
        guard let milliseconds = Double(timestamp) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

struct CursorTokenUsage: Decodable {
    var inputTokens: Int64?
    var outputTokens: Int64?
    var cacheWriteTokens: Int64?
    var cacheReadTokens: Int64?
}

struct CursorSpendResponse: Decodable {
    /// Epoch milliseconds.
    var subscriptionCycleStart: Double?
}
