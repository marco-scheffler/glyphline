import Foundation

enum OpenAIUsageAdapterError: Error, Equatable {
    case invalidRequest
    /// The URL loading system returned something that was not an HTTP response.
    case invalidResponse
    /// A non-2xx status. The code is carried so a refused credential can be told
    /// apart from a provider outage; it never carries the secret or any header.
    case requestFailed(statusCode: Int)
    case decodeFailed
}

struct OpenAIUsageAdapter: ProviderAdapter {
    let providerID: ProviderID = .openAI

    var session: URLSession
    /// Forced to UTC in `init` and not settable afterwards, so the invariant holds
    /// for every copy `scoped(to:)` makes.
    private(set) var calendar: Calendar
    var now: @Sendable () -> Date

    /// Set by `scoped(to:)` during backfill. Nil means "the current billing period".
    var window: DateInterval?

    var scopedIsNoOp: Bool { false }

    func scoped(to interval: DateInterval) -> any ProviderAdapter {
        var copy = self
        copy.window = interval
        return copy
    }

    init(
        session: URLSession = .shared,
        calendar: Calendar = Calendar(identifier: .gregorian),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.now = now
        // Every bucket-computing component on this branch works in UTC, and this
        // one must too. `periodStart` becomes the `start_time` the usage and cost
        // endpoints are queried with, and backfill supplies UTC-midnight slices for
        // the same parameter. A local calendar would make routine sync ask for a
        // window starting at local midnight while backfill asks for UTC midnight,
        // so the two would key the same real day under different bucket boundaries.
        // The unique key is (accountID, providerID, bucketStart, bucketEnd,
        // modelKey), so both rows would survive and `makeAccountSummary` would sum
        // them: doubled tokens and doubled cost.
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        self.calendar = utc
    }

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        let syncedAt = now()
        // Snapped to a UTC day boundary. A month interval in a UTC calendar already
        // is one; the snap also covers the `syncedAt` fallback, which is a mid-day
        // instant and would otherwise be sent as a `start_time` that cuts a bucket
        // in half — the fragment-for-a-whole-day defect this branch has fixed three
        // times over.
        let periodStart = calendar.startOfDay(
            for: window?.start
                ?? calendar.dateInterval(of: .month, for: syncedAt)?.start
                ?? syncedAt
        )
        let periodEnd = window?.end ?? syncedAt
        let resetAt = window == nil
            ? calendar.date(byAdding: .month, value: 1, to: periodStart)
            : nil

        let usage: OpenAIUsageResponse
        let costs: OpenAICostsResponse
        do {
            usage = try await fetchUsage(secret: secret, start: periodStart, end: periodEnd)
            costs = try await fetchCosts(secret: secret, start: periodStart, end: periodEnd)
        } catch OpenAIUsageAdapterError.requestFailed(let statusCode)
            where ProviderHTTPStatus.isCredentialRejection(statusCode) {
            // The other two adapters already degrade here. Without it a user who
            // pasted a plain API key — the default selection when adding an account
            // — saw only "Sync failed.", and because a thrown sync never reaches
            // `applySuccessfulSyncResult`, the stored capabilities kept saying
            // `.exact` beside totals that had stopped moving.
            return unavailableResult(
                for: account,
                message: "OpenAI rejected the credential. An organization admin key is required."
            )
        }

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
            // A backfill slice is a historic window, not a billing period. Reporting
            // one would overwrite the account's real period with a past week.
            billingPeriod: window == nil
                ? BillingPeriod(startsAt: periodStart, endsAt: nil, resetAt: resetAt)
                : nil,
            usageSnapshots: makeUsageSnapshots(from: usage, accountID: account.id),
            costSnapshots: makeCostSnapshots(from: costs, accountID: account.id),
            estimateSnapshots: [],
            syncedAt: syncedAt
        )
    }

    private func unavailableResult(for account: Account, message: String) -> ProviderSyncResult {
        ProviderSyncResult(
            providerID: .openAI,
            accountID: account.id,
            capabilities: ProviderCapabilities(
                supportsUsage: false,
                supportsActualCost: false,
                supportsResetDate: false,
                supportsModelBreakdown: false,
                dataQuality: .unavailable,
                message: message
            ),
            billingPeriod: nil,
            usageSnapshots: [],
            costSnapshots: [],
            estimateSnapshots: [],
            syncedAt: now()
        )
    }

    func makeUsageSnapshots(from response: OpenAIUsageResponse, accountID: UUID) -> [UsageSnapshot] {
        response.data.flatMap { bucket in
            let bucketStart = Date(timeIntervalSince1970: TimeInterval(bucket.startTime))
            let bucketEnd = Date(timeIntervalSince1970: TimeInterval(bucket.endTime))

            return bucket.results.map { result in
                UsageSnapshot(
                    id: SnapshotIdentity.make(
                        accountID: accountID,
                        providerID: providerID,
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
                guard let value = result.amount?.value,
                      let currency = result.amount?.currency else {
                    continue
                }
                let amountMicros = MoneyAmount.micros(fromDollars: value)

                let discriminatorParts = [
                    result.lineItem ?? "cost",
                    result.projectID ?? "project",
                    result.apiKeyID ?? "key",
                    "\(index)",
                ]

                snapshots.append(
                    CostSnapshot(
                        id: SnapshotIdentity.make(
                            accountID: accountID,
                            providerID: providerID,
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
            throw OpenAIUsageAdapterError.requestFailed(statusCode: httpResponse.statusCode)
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
}
