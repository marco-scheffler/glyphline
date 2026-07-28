import Foundation

enum ClaudeUsageAdapterError: Error, Equatable {
    case invalidRequest
    case invalidResponse
    case decodeFailed
}

struct ClaudeUsageAdapter: ProviderAdapter {
    enum Mode: Sendable, Equatable {
        case requiresAdminKey
        case adminAPI
        case localLogs
    }

    let providerID: ProviderID = .claude
    var mode: Mode
    var session: URLSession
    var now: @Sendable () -> Date
    var calendar: Calendar
    var logReader: ClaudeCodeLogReader?

    /// Set by `scoped(to:)` during backfill. Nil means "the current billing month".
    var window: DateInterval?

    /// Only the Admin API can address arbitrary history. `localLogs` reads whole
    /// files incrementally and cannot be narrowed to a date range.
    var scopedIsNoOp: Bool { mode != .adminAPI }

    func scoped(to interval: DateInterval) -> any ProviderAdapter {
        guard mode == .adminAPI else { return self }
        var copy = self
        copy.window = interval
        return copy
    }

    init(
        mode: Mode,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = Calendar(identifier: .gregorian),
        logReader: ClaudeCodeLogReader? = nil
    ) {
        self.mode = mode
        self.session = session
        self.now = now
        // The Admin API is queried with UTC `starting_at`/`ending_at` and
        // `bucket_width=1d`, so the buckets it returns are UTC. Deriving period
        // boundaries with a local calendar would shift them away from the
        // buckets the API actually returned. `CursorUsageAdapter` and
        // `ClaudeCodeLogReader` already force UTC; this matches them.
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        self.calendar = utc
        self.logReader = logReader
    }

    var requiresSecret: Bool { mode != .localLogs }

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        switch mode {
        case .adminAPI:
            return try await syncAdminAPI(account: account, secret: secret)
        case .localLogs:
            guard let logReader else {
                return unavailableResult(
                    for: account,
                    message: "Local Claude Code logs are not configured."
                )
            }

            let snapshots = try logReader.read(accountID: account.id)

            return ProviderSyncResult(
                providerID: .claude,
                accountID: account.id,
                capabilities: ProviderCapabilities(
                    supportsUsage: true,
                    supportsActualCost: false,
                    supportsResetDate: false,
                    supportsModelBreakdown: true,
                    dataQuality: .partial,
                    message: "Covers Claude Code usage on this Mac only, not claude.ai. Costs are estimated."
                ),
                billingPeriod: nil,
                usageSnapshots: snapshots,
                costSnapshots: [],
                estimateSnapshots: [],
                syncedAt: now()
            )
        case .requiresAdminKey:
            return unavailableResult(
                for: account,
                message: "Claude usage requires an organization admin credential."
            )
        }
    }

    private func syncAdminAPI(account: Account, secret: String) async throws -> ProviderSyncResult {
        let syncedAt = now()
        let periodStart = window?.start
            ?? calendar.dateInterval(of: .month, for: syncedAt)?.start
            ?? syncedAt
        let periodEnd = window?.end ?? syncedAt

        let usage: [ClaudeUsageBucket]
        let costs: [ClaudeCostBucket]
        do {
            usage = try await fetchUsage(secret: secret, start: periodStart, end: periodEnd)
            costs = try await fetchCosts(secret: secret, start: periodStart, end: periodEnd)
        } catch ClaudeUsageAdapterError.invalidResponse {
            return unavailableResult(
                for: account,
                message: "Claude rejected the credential. An organization admin key is required."
            )
        }

        return ProviderSyncResult(
            providerID: .claude,
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
                ? BillingPeriod(
                    startsAt: periodStart,
                    endsAt: nil,
                    resetAt: calendar.date(byAdding: .month, value: 1, to: periodStart)
                )
                : nil,
            usageSnapshots: makeUsageSnapshots(from: usage, accountID: account.id),
            costSnapshots: makeCostSnapshots(from: costs, accountID: account.id),
            estimateSnapshots: [],
            syncedAt: syncedAt
        )
    }

    private func unavailableResult(for account: Account, message: String) -> ProviderSyncResult {
        ProviderSyncResult(
            providerID: .claude,
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

    func makeUsageSnapshots(from buckets: [ClaudeUsageBucket], accountID: UUID) -> [UsageSnapshot] {
        buckets.flatMap { bucket -> [UsageSnapshot] in
            guard let start = Self.date(from: bucket.startingAt),
                  let end = Self.date(from: bucket.endingAt) else {
                return []
            }

            return bucket.results.map { result in
                UsageSnapshot(
                    id: SnapshotIdentity.make(
                        accountID: accountID,
                        providerID: .claude,
                        bucketStart: start,
                        bucketEnd: end,
                        discriminator: result.model ?? "usage"
                    ),
                    accountID: accountID,
                    providerID: .claude,
                    bucketStart: start,
                    bucketEnd: end,
                    model: result.model,
                    inputTokens: result.uncachedInputTokens,
                    cacheCreationTokens: result.cacheCreationTokens,
                    cacheReadTokens: result.cacheReadInputTokens,
                    outputTokens: result.outputTokens,
                    requests: nil,
                    quality: .exact
                )
            }
        }
    }

    func makeCostSnapshots(from buckets: [ClaudeCostBucket], accountID: UUID) -> [CostSnapshot] {
        buckets.flatMap { bucket -> [CostSnapshot] in
            guard let start = Self.date(from: bucket.startingAt),
                  let end = Self.date(from: bucket.endingAt) else {
                return []
            }

            // One bucket carries many line items in one currency; the ledger stores one row per currency.
            var totalsByCurrency: [String: Decimal] = [:]
            for result in bucket.results {
                guard let value = Decimal(string: result.amount) else { continue }
                totalsByCurrency[result.currency, default: 0] += value
            }

            return totalsByCurrency.map { currency, cents in
                CostSnapshot(
                    id: SnapshotIdentity.make(
                        accountID: accountID,
                        providerID: .claude,
                        bucketStart: start,
                        bucketEnd: end,
                        discriminator: currency
                    ),
                    accountID: accountID,
                    providerID: .claude,
                    bucketStart: start,
                    bucketEnd: end,
                    amountMicros: MoneyAmount.micros(fromCents: cents),
                    currency: currency,
                    quality: .exact
                )
            }
        }
    }

    private func fetchUsage(secret: String, start: Date, end: Date) async throws -> [ClaudeUsageBucket] {
        var buckets: [ClaudeUsageBucket] = []
        var page: String?

        repeat {
            let request = try Self.makeUsageRequest(secret: secret, start: start, end: end, page: page)
            let report: ClaudeUsageReport = try await perform(request)
            buckets.append(contentsOf: report.data)
            page = report.hasMore ? report.nextPage : nil
        } while page != nil

        return buckets
    }

    private func fetchCosts(secret: String, start: Date, end: Date) async throws -> [ClaudeCostBucket] {
        var buckets: [ClaudeCostBucket] = []
        var page: String?

        repeat {
            let request = try Self.makeCostRequest(secret: secret, start: start, end: end, page: page)
            let report: ClaudeCostReport = try await perform(request)
            buckets.append(contentsOf: report.data)
            page = report.hasMore ? report.nextPage : nil
        } while page != nil

        return buckets
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageAdapterError.invalidResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            throw ClaudeUsageAdapterError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ClaudeUsageAdapterError.decodeFailed
        }
    }

    static func makeUsageRequest(secret: String, start: Date, end: Date, page: String?) throws -> URLRequest {
        try makeRequest(
            path: "/v1/organizations/usage_report/messages",
            secret: secret,
            start: start,
            end: end,
            page: page,
            extraQueryItems: [
                URLQueryItem(name: "group_by[]", value: "model"),
                URLQueryItem(name: "limit", value: "31"),
            ]
        )
    }

    static func makeCostRequest(secret: String, start: Date, end: Date, page: String?) throws -> URLRequest {
        try makeRequest(
            path: "/v1/organizations/cost_report",
            secret: secret,
            start: start,
            end: end,
            page: page,
            extraQueryItems: [URLQueryItem(name: "group_by[]", value: "description")]
        )
    }

    private static func makeRequest(
        path: String,
        secret: String,
        start: Date,
        end: Date,
        page: String?,
        extraQueryItems: [URLQueryItem]
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.anthropic.com"
        components.path = path

        var queryItems = [
            URLQueryItem(name: "starting_at", value: rfc3339(start)),
            URLQueryItem(name: "ending_at", value: rfc3339(end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
        ]
        queryItems.append(contentsOf: extraQueryItems)
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: page))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ClaudeUsageAdapterError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Admin keys authenticate with x-api-key; OAuth tokens use a bearer header.
        if secret.hasPrefix("sk-ant-admin") {
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
        } else {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    /// A fresh formatter per call: `ISO8601DateFormatter` is not `Sendable`, and a
    /// shared static one would need an unsafe opt-out for a negligible saving.
    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func rfc3339(_ date: Date) -> String {
        makeFormatter().string(from: date)
    }

    static func date(from string: String) -> Date? {
        makeFormatter().date(from: string)
    }
}
