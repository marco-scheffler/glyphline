import Foundation

enum CursorUsageAdapterError: Error, Equatable {
    case invalidRequest
    case invalidResponse
    case decodeFailed
}

struct CursorUsageAdapter: ProviderAdapter {
    enum Mode: Sendable, Equatable {
        case localStatusOnly
        case teamAPI
    }

    let providerID: ProviderID = .cursor
    var mode: Mode
    var session: URLSession
    var now: @Sendable () -> Date
    var calendar: Calendar

    /// Set by `scoped(to:)` during backfill. Nil means the rolling 30-day window.
    var window: DateInterval?

    /// Only the team API can address arbitrary history.
    var scopedIsNoOp: Bool { mode != .teamAPI }

    func scoped(to interval: DateInterval) -> any ProviderAdapter {
        guard mode == .teamAPI else { return self }
        var copy = self
        copy.window = interval
        return copy
    }

    init(
        mode: Mode,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        self.mode = mode
        self.session = session
        self.now = now
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        self.calendar = utc
    }

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        switch mode {
        case .teamAPI:
            return try await syncTeamAPI(account: account, secret: secret)
        case .localStatusOnly:
            return unavailableResult(
                for: account,
                message: "Cursor usage requires a team admin API key. Individual seats have no documented API."
            )
        }
    }

    private func syncTeamAPI(account: Account, secret: String) async throws -> ProviderSyncResult {
        let syncedAt = now()

        // Backfill supplies UTC-day-aligned slices, so the same "never emit a
        // fragment as a whole-day bucket" guarantee `eventsWindowStart` gives the
        // default window holds for a scoped one too.
        let windowStart = window?.start ?? eventsWindowStart(for: syncedAt)
        let windowEnd = window?.end ?? syncedAt

        let events: [CursorUsageEvent]
        do {
            events = try await fetchEvents(secret: secret, start: windowStart, end: windowEnd)
        } catch CursorUsageAdapterError.invalidResponse {
            return unavailableResult(
                for: account,
                message: "Cursor rejected the credential. A team admin API key is required."
            )
        }

        // The billing period is secondary. Losing it must not discard usage that
        // was already fetched successfully, so it degrades to "no reset date"
        // rather than to "nothing available".
        let cycleStart = try? await fetchCycleStart(secret: secret)

        let (usage, costs) = aggregate(events: events, accountID: account.id)

        return ProviderSyncResult(
            providerID: .cursor,
            accountID: account.id,
            capabilities: ProviderCapabilities(
                supportsUsage: true,
                supportsActualCost: true,
                supportsResetDate: cycleStart != nil,
                supportsModelBreakdown: true,
                // Usage and cost were fetched successfully, so they are exact.
                // Only the billing period may be missing, and that is said plainly.
                dataQuality: .exact,
                message: cycleStart == nil
                    ? "Usage and cost are exact. Cursor did not return a billing cycle start, so there is no reset date."
                    : nil
            ),
            billingPeriod: cycleStart.map {
                BillingPeriod(
                    startsAt: $0,
                    endsAt: nil,
                    resetAt: calendar.date(byAdding: .month, value: 1, to: $0)
                )
            },
            usageSnapshots: usage,
            costSnapshots: costs,
            estimateSnapshots: [],
            syncedAt: syncedAt
        )
    }

    /// The start of the events window, snapped to a UTC day boundary.
    ///
    /// Not a rolling 30-days-from-now instant: `aggregate` labels every bucket as
    /// a whole day, and the ledger upsert *replaces* a bucket rather than adding
    /// to it, so a window starting mid-day would emit the oldest day as a fragment
    /// and shrink that day's stored total on every successive sync. 29 days back
    /// plus today stays inside the endpoint's 30-day cap. Today's bucket is still
    /// partial, but it only ever grows, so replacing it is safe.
    func eventsWindowStart(for syncedAt: Date) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: -29, to: syncedAt) ?? syncedAt)
    }

    private func unavailableResult(for account: Account, message: String) -> ProviderSyncResult {
        ProviderSyncResult(
            providerID: .cursor,
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

    private struct UsageKey: Hashable {
        var dayStart: Date
        var model: String?
    }

    private struct UsageTotals {
        var input: Int64 = 0
        var cacheWrite: Int64 = 0
        var cacheRead: Int64 = 0
        var output: Int64 = 0
        var requests: Int64 = 0
    }

    func aggregate(events: [CursorUsageEvent], accountID: UUID) -> ([UsageSnapshot], [CostSnapshot]) {
        var usageTotals: [UsageKey: UsageTotals] = [:]
        var centsByDay: [Date: Decimal] = [:]

        for event in events {
            guard let timestamp = event.date else { continue }
            let dayStart = calendar.startOfDay(for: timestamp)

            if let cents = event.chargedCents {
                centsByDay[dayStart, default: 0] += cents
            }

            let key = UsageKey(dayStart: dayStart, model: event.model)
            usageTotals[key, default: UsageTotals()].requests += 1

            guard let tokens = event.tokenUsage else { continue }
            usageTotals[key, default: UsageTotals()].input += tokens.inputTokens ?? 0
            usageTotals[key, default: UsageTotals()].cacheWrite += tokens.cacheWriteTokens ?? 0
            usageTotals[key, default: UsageTotals()].cacheRead += tokens.cacheReadTokens ?? 0
            usageTotals[key, default: UsageTotals()].output += tokens.outputTokens ?? 0
        }

        let usage = usageTotals.map { key, totals -> UsageSnapshot in
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: key.dayStart) ?? key.dayStart

            return UsageSnapshot(
                id: SnapshotIdentity.make(
                    accountID: accountID,
                    providerID: .cursor,
                    bucketStart: key.dayStart,
                    bucketEnd: dayEnd,
                    discriminator: key.model ?? "usage"
                ),
                accountID: accountID,
                providerID: .cursor,
                bucketStart: key.dayStart,
                bucketEnd: dayEnd,
                model: key.model,
                inputTokens: totals.input,
                cacheCreationTokens: totals.cacheWrite,
                cacheReadTokens: totals.cacheRead,
                outputTokens: totals.output,
                requests: totals.requests,
                quality: .exact
            )
        }
        .sorted { $0.bucketStart < $1.bucketStart }

        let costs = centsByDay.map { dayStart, cents -> CostSnapshot in
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

            return CostSnapshot(
                id: SnapshotIdentity.make(
                    accountID: accountID,
                    providerID: .cursor,
                    bucketStart: dayStart,
                    bucketEnd: dayEnd,
                    discriminator: "USD"
                ),
                accountID: accountID,
                providerID: .cursor,
                bucketStart: dayStart,
                bucketEnd: dayEnd,
                amountMicros: MoneyAmount.micros(fromCents: cents),
                currency: "USD",
                quality: .exact
            )
        }
        .sorted { $0.bucketStart < $1.bucketStart }

        return (usage, costs)
    }

    private func fetchEvents(secret: String, start: Date, end: Date) async throws -> [CursorUsageEvent] {
        var events: [CursorUsageEvent] = []
        var page = 1

        while true {
            let request = try Self.makeEventsRequest(secret: secret, start: start, end: end, page: page)
            let response: CursorUsageEventsResponse = try await perform(request)
            events.append(contentsOf: response.usageEvents)

            guard response.pagination?.hasNextPage == true else { break }
            page += 1
        }

        return events
    }

    private func fetchCycleStart(secret: String) async throws -> Date? {
        let request = try Self.makeSpendRequest(secret: secret)
        let response: CursorSpendResponse = try await perform(request)

        return response.subscriptionCycleStart.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CursorUsageAdapterError.invalidResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            throw CursorUsageAdapterError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CursorUsageAdapterError.decodeFailed
        }
    }

    static func makeEventsRequest(secret: String, start: Date, end: Date, page: Int) throws -> URLRequest {
        try makeRequest(
            path: "/teams/filtered-usage-events",
            secret: secret,
            body: [
                "startDate": Int(start.timeIntervalSince1970 * 1000),
                "endDate": Int(end.timeIntervalSince1970 * 1000),
                "page": page,
                "pageSize": 1000,
            ]
        )
    }

    static func makeSpendRequest(secret: String) throws -> URLRequest {
        try makeRequest(path: "/teams/spend", secret: secret, body: ["page": 1, "pageSize": 100])
    }

    private static func makeRequest(path: String, secret: String, body: [String: Int]) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.cursor.com"
        components.path = path

        guard let url = components.url else {
            throw CursorUsageAdapterError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Basic auth: the API key is the username, the password is empty.
        let credentials = Data("\(secret):".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return request
    }
}
