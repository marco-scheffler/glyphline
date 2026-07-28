import Foundation

struct OpenAIUsageResponse: Decodable {
    var object: String
    var data: [OpenAIUsageBucket]
    var hasMore: Bool
    var nextPage: String?

    enum CodingKeys: String, CodingKey {
        case object
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct OpenAIUsageBucket: Decodable {
    var object: String?
    var startTime: Int64
    var endTime: Int64
    var results: [OpenAIUsageResult]

    enum CodingKeys: String, CodingKey {
        case object
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

struct OpenAIUsageResult: Decodable {
    var object: String?
    var model: String?
    /// As reported: **inclusive** of `inputCachedTokens`, unlike Anthropic's
    /// `uncached_input_tokens`. Use `uncachedInputTokens` for the ledger.
    var inputTokens: Int64
    /// The cached portion of `inputTokens`. Priced far below fresh input, so the
    /// ledger records it as a cache read rather than folding it into input.
    var inputCachedTokens: Int64
    var outputTokens: Int64
    var requests: Int64

    /// `inputTokens` with the cached portion removed, so the two can be stored as
    /// separate token classes without counting the cached tokens twice.
    ///
    /// Clamped: a cached count larger than the total it is drawn from would be a
    /// provider bug, and a negative input count would corrupt every total derived
    /// from it. Clamping keeps `uncachedInputTokens + inputCachedTokens` equal to
    /// `inputTokens` in every case that is arithmetically possible.
    var uncachedInputTokens: Int64 {
        max(0, inputTokens - min(max(0, inputCachedTokens), inputTokens))
    }

    /// The cached portion, clamped alongside `uncachedInputTokens` so the pair
    /// always sums back to `inputTokens`.
    var cachedInputTokens: Int64 {
        min(max(0, inputCachedTokens), max(0, inputTokens))
    }

    enum CodingKeys: String, CodingKey {
        case object
        case model
        case inputTokens = "input_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case outputTokens = "output_tokens"
        case requests = "num_model_requests"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try container.decodeIfPresent(String.self, forKey: .object)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        inputCachedTokens = try container.decodeIfPresent(Int64.self, forKey: .inputCachedTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        requests = try container.decodeIfPresent(Int64.self, forKey: .requests) ?? 0
    }
}

struct OpenAICostsResponse: Decodable {
    var object: String
    var data: [OpenAICostBucket]
    var hasMore: Bool
    var nextPage: String?

    enum CodingKeys: String, CodingKey {
        case object
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct OpenAICostBucket: Decodable {
    var object: String?
    var startTime: Int64
    var endTime: Int64
    var results: [OpenAICostResult]

    enum CodingKeys: String, CodingKey {
        case object
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

struct OpenAICostResult: Decodable {
    var object: String?
    var amount: OpenAICostAmount?
    var lineItem: String?
    var projectID: String?
    var apiKeyID: String?
    var quantity: Decimal?

    enum CodingKeys: String, CodingKey {
        case object
        case amount
        case lineItem = "line_item"
        case projectID = "project_id"
        case apiKeyID = "api_key_id"
        case quantity
    }
}

struct OpenAICostAmount: Decodable {
    var value: Decimal?
    var currency: String?
}
