import Foundation

struct OpenAIUsageResponse: Decodable {
    var data: [OpenAIUsageBucket]
}

struct OpenAIUsageBucket: Decodable {
    var startTime: Int64
    var endTime: Int64
    var results: [OpenAIUsageResult]

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

struct OpenAIUsageResult: Decodable {
    var model: String?
    var inputTokens: Int64
    var outputTokens: Int64
    var requests: Int64

    enum CodingKeys: String, CodingKey {
        case model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case requests = "num_model_requests"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        requests = try container.decodeIfPresent(Int64.self, forKey: .requests) ?? 0
    }
}
