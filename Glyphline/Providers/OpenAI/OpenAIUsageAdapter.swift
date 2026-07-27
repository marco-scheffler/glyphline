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
        let usageSnapshots = makeUsageSnapshots(from: usage, accountID: account.id)
        let usageQuality: DataQuality = usageSnapshots.isEmpty ? .unavailable : .exact
        let capabilityMessage = usageSnapshots.isEmpty
            ? "No OpenAI usage buckets were returned for the current billing period."
            : "OpenAI usage is exact. Actual cost sync is not implemented in Task 9."

        return ProviderSyncResult(
            providerID: .openAI,
            accountID: account.id,
            capabilities: ProviderCapabilities(
                supportsUsage: true,
                supportsActualCost: false,
                supportsResetDate: false,
                supportsModelBreakdown: true,
                dataQuality: usageQuality,
                message: capabilityMessage
            ),
            billingPeriod: BillingPeriod(
                startsAt: periodStart,
                endsAt: nil,
                resetAt: periodEnd
            ),
            usageSnapshots: usageSnapshots,
            costSnapshots: [],
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
                        model: result.model
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

    func makeUsageRequest(secret: String, start: Date, end: Date) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.openai.com"
        components.path = "/v1/organization/usage/completions"
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "group_by", value: "model")
        ]

        guard let url = components.url else {
            throw OpenAIUsageAdapterError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")

        return request
    }

    private func fetchUsage(secret: String, start: Date, end: Date) async throws -> OpenAIUsageResponse {
        let request = try makeUsageRequest(secret: secret, start: start, end: end)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIUsageAdapterError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw OpenAIUsageAdapterError.requestFailed
        }

        do {
            return try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)
        } catch {
            throw OpenAIUsageAdapterError.decodeFailed
        }
    }

    private func makeSnapshotID(
        accountID: UUID,
        bucketStart: Date,
        bucketEnd: Date,
        model: String?
    ) -> UUID {
        let key = [
            accountID.uuidString,
            providerID.rawValue,
            String(bucketStart.timeIntervalSince1970),
            String(bucketEnd.timeIntervalSince1970),
            model ?? "nil"
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
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: upper >> ((7 - index) * 8))
            bytes[index + 8] = UInt8(truncatingIfNeeded: lower >> ((7 - index) * 8))
        }

        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes
    }
}
