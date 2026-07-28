import Foundation

struct ClaudeUsageReport: Decodable {
    var data: [ClaudeUsageBucket]
    var hasMore: Bool
    var nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct ClaudeUsageBucket: Decodable {
    var startingAt: String
    var endingAt: String
    var results: [ClaudeUsageResult]

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

struct ClaudeUsageResult: Decodable {
    var model: String?
    var uncachedInputTokens: Int64
    var cacheCreation: ClaudeCacheCreation?
    var cacheReadInputTokens: Int64
    var outputTokens: Int64

    enum CodingKeys: String, CodingKey {
        case model
        case uncachedInputTokens = "uncached_input_tokens"
        case cacheCreation = "cache_creation"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
    }

    var cacheCreationTokens: Int64 {
        (cacheCreation?.ephemeral5mInputTokens ?? 0) + (cacheCreation?.ephemeral1hInputTokens ?? 0)
    }
}

struct ClaudeCacheCreation: Decodable {
    var ephemeral5mInputTokens: Int64
    var ephemeral1hInputTokens: Int64

    enum CodingKeys: String, CodingKey {
        case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
        case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
    }
}

struct ClaudeCostReport: Decodable {
    var data: [ClaudeCostBucket]
    var hasMore: Bool
    var nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct ClaudeCostBucket: Decodable {
    var startingAt: String
    var endingAt: String
    var results: [ClaudeCostResult]

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

struct ClaudeCostResult: Decodable {
    /// Decimal string in the lowest currency unit — cents, not dollars.
    var amount: String
    var currency: String
    var model: String?
    var costType: String?
    var tokenType: String?

    enum CodingKeys: String, CodingKey {
        case amount
        case currency
        case model
        case costType = "cost_type"
        case tokenType = "token_type"
    }
}
