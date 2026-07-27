import Foundation

enum OpenAIUsageAdapterError: Error {
    case invalidRequest
    case invalidResponse
    case requestFailed
    case decodeFailed
}

struct OpenAIUsageAdapter: ProviderAdapter {
    let providerID: ProviderID = .openAI

    var session: URLSession
    var calendar: Calendar
    var now: @Sendable () -> Date

    init(
        session: URLSession = .shared,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.calendar = calendar
        self.now = now
    }

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        let syncedAt = now()
        let periodStart = calendar.dateInterval(of: .month, for: syncedAt)?.start ?? syncedAt
        let periodEnd = calendar.date(byAdding: .month, value: 1, to: periodStart)

        let usage = try await fetchUsage(secret: secret, start: periodStart, end: syncedAt)
        let costs = try await fetchCosts(secret: secret, start: periodStart, end: syncedAt)

        return ProviderSyncResult(
            providerID: .openAI,
            accountID: account.id,
            capabilities: ProviderCapabilities(
                supportsUsage: true,
                supportsActualCost: true,
                supportsResetDate: false,
                supportsModelBreakdown: true,
                dataQuality: .exact,
                message: nil
            ),
            billingPeriod: BillingPeriod(
                startsAt: periodStart,
                endsAt: nil,
                resetAt: periodEnd
            ),
            usageSnapshots: makeUsageSnapshots(from: usage, accountID: account.id),
            costSnapshots: makeCostSnapshots(from: costs, accountID: account.id),
            estimateSnapshots: [],
            syncedAt: syncedAt
        )
    }

    func makeUsageSnapshots(from response: OpenAIUsageResponse, accountID: UUID) -> [UsageSnapshot] {
        response.data.flatMap { bucket in
            let bucketStart = Date(timeIntervalSince1970: TimeInterval(bucket.startTime))
            let bucketEnd = Date(timeIntervalSince1970: TimeInterval(bucket.endTime))

            return bucket.results.map { result in
                UsageSnapshot(
                    id: makeSnapshotID(
                        accountID: accountID,
                        bucketStart: bucketStart,
                        bucketEnd: bucketEnd,
                        discriminator: result.model ?? "usage"
                    ),
                    accountID: accountID,
                    providerID: .openAI,
                    bucketStart: bucketStart,
                    bucketEnd: bucketEnd,
                    model: result.model,
                    inputTokens: result.inputTokens,
                    outputTokens: result.outputTokens,
                    requests: result.requests,
                    quality: .exact
                )
            }
        }
    }

    func makeCostSnapshots(from response: OpenAICostsResponse, accountID: UUID) -> [CostSnapshot] {
        response.data.flatMap { bucket in
            let bucketStart = Date(timeIntervalSince1970: TimeInterval(bucket.startTime))
            let bucketEnd = Date(timeIntervalSince1970: TimeInterval(bucket.endTime))
            var snapshots: [CostSnapshot] = []

            for (index, result) in bucket.results.enumerated() {
                guard let amountMicros = micros(from: result.amount?.value),
                      let currency = result.amount?.currency else {
                    continue
                }

                let discriminatorParts = [
                    result.lineItem ?? "cost",
                    result.projectID ?? "project",
                    result.apiKeyID ?? "key",
                    "\(index)",
                ]

                snapshots.append(
                    CostSnapshot(
                        id: makeSnapshotID(
                            accountID: accountID,
                            bucketStart: bucketStart,
                            bucketEnd: bucketEnd,
                            discriminator: discriminatorParts.joined(separator: "|")
                        ),
                        accountID: accountID,
                        providerID: .openAI,
                        bucketStart: bucketStart,
                        bucketEnd: bucketEnd,
                        amountMicros: amountMicros,
                        currency: currency,
                        quality: .exact
                    )
                )
            }

            return snapshots
        }
    }

    private func fetchUsage(secret: String, start: Date, end: Date) async throws -> OpenAIUsageResponse {
        var buckets: [OpenAIUsageBucket] = []
        var page: String?

        repeat {
            let response = try await fetchUsagePage(secret: secret, start: start, end: end, page: page)
            buckets.append(contentsOf: response.data)
            page = response.hasMore ? response.nextPage : nil
        } while page != nil

        return OpenAIUsageResponse(object: "page", data: buckets, hasMore: false, nextPage: nil)
    }

    private func fetchCosts(secret: String, start: Date, end: Date) async throws -> OpenAICostsResponse {
        var buckets: [OpenAICostBucket] = []
        var page: String?

        repeat {
            let response = try await fetchCostsPage(secret: secret, start: start, end: end, page: page)
            buckets.append(contentsOf: response.data)
            page = response.hasMore ? response.nextPage : nil
        } while page != nil

        return OpenAICostsResponse(object: "page", data: buckets, hasMore: false, nextPage: nil)
    }

    private func fetchUsagePage(
        secret: String,
        start: Date,
        end: Date,
        page: String?
    ) async throws -> OpenAIUsageResponse {
        let request = try makeUsageRequest(secret: secret, start: start, end: end, page: page)
        return try await perform(request, as: OpenAIUsageResponse.self)
    }

    private func fetchCostsPage(
        secret: String,
        start: Date,
        end: Date,
        page: String?
    ) async throws -> OpenAICostsResponse {
        let request = try makeCostsRequest(secret: secret, start: start, end: end, page: page)
        return try await perform(request, as: OpenAICostsResponse.self)
    }

    private func perform<Response: Decodable>(_ request: URLRequest, as type: Response.Type) async throws -> Response {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIUsageAdapterError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw OpenAIUsageAdapterError.requestFailed
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OpenAIUsageAdapterError.decodeFailed
        }
    }

    private func makeUsageRequest(
        secret: String,
        start: Date,
        end: Date,
        page: String?
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.openai.com"
        components.path = "/v1/organization/usage/completions"

        var queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
            URLQueryItem(name: "group_by", value: "model"),
        ]

        if let page {
            queryItems.append(URLQueryItem(name: "page", value: page))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw OpenAIUsageAdapterError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeCostsRequest(
        secret: String,
        start: Date,
        end: Date,
        page: String?
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.openai.com"
        components.path = "/v1/organization/costs"

        var queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
        ]

        if let page {
            queryItems.append(URLQueryItem(name: "page", value: page))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw OpenAIUsageAdapterError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func micros(from value: Decimal?) -> Int64? {
        guard var value else {
            return nil
        }

        var scaled = Decimal()
        NSDecimalMultiplyByPowerOf10(&scaled, &value, 6, .plain)
        return NSDecimalNumber(decimal: scaled).int64Value
    }

    private func makeSnapshotID(
        accountID: UUID,
        bucketStart: Date,
        bucketEnd: Date,
        discriminator: String
    ) -> UUID {
        let key = [
            accountID.uuidString,
            providerID.rawValue,
            String(bucketStart.timeIntervalSince1970),
            String(bucketEnd.timeIntervalSince1970),
            discriminator,
        ].joined(separator: "|")

        let bytes = Self.makeUUIDBytes(from: key)
        let uuidString = bytes.enumerated().map { index, byte in
            let fragment = String(format: "%02x", byte)
            switch index {
            case 4, 6, 8, 10:
                return "-\(fragment)"
            default:
                return fragment
            }
        }.joined()

        return UUID(uuidString: uuidString) ?? UUID()
    }

    private static func makeUUIDBytes(from key: String) -> [UInt8] {
        var upper = UInt64(0xcbf29ce484222325)
        var lower = UInt64(0x84222325cbf29ce4)

        for byte in key.utf8 {
            upper = (upper ^ UInt64(byte)) &* 0x100000001b3
            lower = (lower ^ UInt64(byte)) &* 0x100000001b3 &+ 0x5c
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0 ..< 8 {
            bytes[index] = UInt8(truncatingIfNeeded: upper >> ((7 - index) * 8))
            bytes[index + 8] = UInt8(truncatingIfNeeded: lower >> ((7 - index) * 8))
        }

        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes
    }
}
