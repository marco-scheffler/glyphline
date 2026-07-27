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
    var inputTokens: Int64
    var outputTokens: Int64
    var requests: Int64

    enum CodingKeys: String, CodingKey {
        case object
        case model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case requests = "num_model_requests"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try container.decodeIfPresent(String.self, forKey: .object)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
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
