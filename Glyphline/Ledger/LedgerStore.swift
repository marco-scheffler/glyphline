import Foundation
import GRDB

enum LedgerStoreError: Error, Equatable {
    /// A write referenced an account that is not in the ledger.
    case unknownAccount
}

private enum LedgerModelIdentity {
    static func makeKey(for model: String?) -> String {
        guard let model else {
            return "nil:"
        }

        return "value:\(model)"
    }
}

struct SyncRun: Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case running
        case succeeded
        case failed
    }

    let id: UUID
    var accountID: UUID
    var providerID: ProviderID
    var startedAt: Date
    var finishedAt: Date?
    var status: Status
    var message: String?
}

struct SyncWatermark: Equatable, Sendable {
    /// Stable identifier for the source. For local logs, the file path.
    var sourceKey: String
    var accountID: UUID
    var fileSize: Int64
    var fileMTime: Date
    var byteOffset: Int64
    var updatedAt: Date
}

struct DailyUsageSummary: Identifiable, Equatable, Sendable {
    let accountID: UUID
    var dayStart: Date
    var inputTokens: Int64
    var cacheCreationTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var outputTokens: Int64
    /// Nil when no contributing snapshot carried a request count.
    var requests: Int64?
    var estimatedAmountMicros: Int64?
    var currency: String?
    var quality: DataQuality

    var id: String { "\(accountID.uuidString)-\(dayStart.timeIntervalSinceReferenceDate)" }
    var totalTokens: Int64 {
        inputTokens + cacheCreationTokens + cacheReadTokens + outputTokens
    }
}

struct AccountUsageSummary: Identifiable, Equatable, Sendable {
    var account: Account
    var capabilities: ProviderCapabilities?
    var billingPeriod: BillingPeriod?
    var latestSyncRun: SyncRun?
    var inputTokens: Int64
    var cacheCreationTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var outputTokens: Int64
    /// Nil when no contributing snapshot carried a request count.
    var requestCount: Int64?
    var actualAmountMicros: Int64?
    var estimatedAmountMicros: Int64?
    var displayCurrency: String?
    var dataQuality: DataQuality

    var id: UUID { account.id }
    var totalTokens: Int64 {
        inputTokens + cacheCreationTokens + cacheReadTokens + outputTokens
    }
    var displayAmountMicros: Int64? { actualAmountMicros ?? estimatedAmountMicros }
    var usesActualCost: Bool { actualAmountMicros != nil }
}

private struct DailyUsageAccumulator {
    let accountID: UUID
    let dayStart: Date
    var inputTokens: Int64 = 0
    var cacheCreationTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var requests: Int64?
    var estimatedAmountMicros: Int64?
    var currency: String?
    var quality: DataQuality?

    mutating func add(_ snapshot: UsageSnapshot) {
        inputTokens += snapshot.inputTokens
        cacheCreationTokens += snapshot.cacheCreationTokens
        cacheReadTokens += snapshot.cacheReadTokens
        outputTokens += snapshot.outputTokens

        // A snapshot without a request count contributes nothing rather than a
        // measured zero; the bucket stays nil until some snapshot reports one.
        if let snapshotRequests = snapshot.requests {
            requests = (requests ?? 0) + snapshotRequests
        }

        mergeQuality(snapshot.quality)
    }

    mutating func add(_ snapshot: EstimateSnapshot) {
        if let currency, currency != snapshot.currency {
            estimatedAmountMicros = nil
            self.currency = nil
            mergeQuality(.partial)
        } else {
            estimatedAmountMicros = (estimatedAmountMicros ?? 0) + snapshot.estimatedAmountMicros
            currency = snapshot.currency
        }

        mergeQuality(snapshot.quality)
    }

    func summary() -> DailyUsageSummary {
        DailyUsageSummary(
            accountID: accountID,
            dayStart: dayStart,
            inputTokens: inputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            requests: requests,
            estimatedAmountMicros: estimatedAmountMicros,
            currency: currency,
            quality: quality ?? .unavailable
        )
    }

    private mutating func mergeQuality(_ candidate: DataQuality) {
        guard let quality else {
            self.quality = candidate
            return
        }

        if quality.isBetterThan(candidate) {
            self.quality = candidate
        }
    }
}

private enum DailySummaryCalendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

private struct SnapshotMoneyTotal {
    var amountMicros: Int64?
    var currency: String?
    var quality: DataQuality?

    mutating func add(amountMicros: Int64, currency: String, quality: DataQuality) {
        if let currentCurrency = self.currency, currentCurrency != currency {
            self.amountMicros = nil
            self.currency = nil
            self.quality = .partial
            return
        }

        self.amountMicros = (self.amountMicros ?? 0) + amountMicros
        self.currency = currency
        mergeQuality(quality)
    }

    private mutating func mergeQuality(_ candidate: DataQuality) {
        guard let quality else {
            self.quality = candidate
            return
        }

        if quality.isBetterThan(candidate) {
            self.quality = candidate
        }
    }
}

private struct AccountRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.accounts

    var id: String
    var providerID: String
    var displayName: String
    var credentialReference: String
    var createdAt: Date
    var isEnabled: Bool

    init(_ account: Account) {
        id = account.id.uuidString
        providerID = account.providerID.rawValue
        displayName = account.displayName
        credentialReference = account.credentialReference
        createdAt = account.createdAt
        isEnabled = account.isEnabled
    }

    var account: Account {
        Account(
            id: UUID(uuidString: id)!,
            providerID: ProviderID(rawValue: providerID)!,
            displayName: displayName,
            credentialReference: credentialReference,
            createdAt: createdAt,
            isEnabled: isEnabled
        )
    }
}

private struct UsageSnapshotRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.usageSnapshots

    var id: String
    var accountID: String
    var providerID: String
    var bucketStart: Date
    var bucketEnd: Date
    var model: String?
    var modelKey: String
    var inputTokens: Int64
    var cacheCreationTokens: Int64
    var cacheReadTokens: Int64
    var outputTokens: Int64
    var requests: Int64?
    var quality: String

    init(_ snapshot: UsageSnapshot) {
        id = snapshot.id.uuidString
        accountID = snapshot.accountID.uuidString
        providerID = snapshot.providerID.rawValue
        bucketStart = snapshot.bucketStart
        bucketEnd = snapshot.bucketEnd
        model = snapshot.model
        modelKey = LedgerModelIdentity.makeKey(for: snapshot.model)
        inputTokens = snapshot.inputTokens
        cacheCreationTokens = snapshot.cacheCreationTokens
        cacheReadTokens = snapshot.cacheReadTokens
        outputTokens = snapshot.outputTokens
        requests = snapshot.requests
        quality = snapshot.quality.rawValue
    }

    var snapshot: UsageSnapshot {
        UsageSnapshot(
            id: UUID(uuidString: id)!,
            accountID: UUID(uuidString: accountID)!,
            providerID: ProviderID(rawValue: providerID)!,
            bucketStart: bucketStart,
            bucketEnd: bucketEnd,
            model: model,
            inputTokens: inputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            requests: requests,
            quality: DataQuality(rawValue: quality)!
        )
    }
}

private struct CostSnapshotRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.costSnapshots

    var id: String
    var accountID: String
    var providerID: String
    var bucketStart: Date
    var bucketEnd: Date
    var amountMicros: Int64
    var currency: String
    var quality: String

    init(_ snapshot: CostSnapshot) {
        id = snapshot.id.uuidString
        accountID = snapshot.accountID.uuidString
        providerID = snapshot.providerID.rawValue
        bucketStart = snapshot.bucketStart
        bucketEnd = snapshot.bucketEnd
        amountMicros = snapshot.amountMicros
        currency = snapshot.currency
        quality = snapshot.quality.rawValue
    }

    var snapshot: CostSnapshot {
        CostSnapshot(
            id: UUID(uuidString: id)!,
            accountID: UUID(uuidString: accountID)!,
            providerID: ProviderID(rawValue: providerID)!,
            bucketStart: bucketStart,
            bucketEnd: bucketEnd,
            amountMicros: amountMicros,
            currency: currency,
            quality: DataQuality(rawValue: quality)!
        )
    }
}

private struct EstimateSnapshotRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.estimateSnapshots

    var id: String
    var accountID: String
    var providerID: String
    var bucketStart: Date
    var bucketEnd: Date
    var estimatedAmountMicros: Int64
    var currency: String
    var quality: String

    init(_ snapshot: EstimateSnapshot) {
        id = snapshot.id.uuidString
        accountID = snapshot.accountID.uuidString
        providerID = snapshot.providerID.rawValue
        bucketStart = snapshot.bucketStart
        bucketEnd = snapshot.bucketEnd
        estimatedAmountMicros = snapshot.estimatedAmountMicros
        currency = snapshot.currency
        quality = snapshot.quality.rawValue
    }

    var snapshot: EstimateSnapshot {
        EstimateSnapshot(
            id: UUID(uuidString: id)!,
            accountID: UUID(uuidString: accountID)!,
            providerID: ProviderID(rawValue: providerID)!,
            bucketStart: bucketStart,
            bucketEnd: bucketEnd,
            estimatedAmountMicros: estimatedAmountMicros,
            currency: currency,
            quality: DataQuality(rawValue: quality)!
        )
    }
}

private struct SyncRunRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.syncRuns

    var id: String
    var accountID: String
    var providerID: String
    var startedAt: Date
    var finishedAt: Date?
    var status: String
    var message: String?

    init(_ syncRun: SyncRun) {
        id = syncRun.id.uuidString
        accountID = syncRun.accountID.uuidString
        providerID = syncRun.providerID.rawValue
        startedAt = syncRun.startedAt
        finishedAt = syncRun.finishedAt
        status = syncRun.status.rawValue
        message = syncRun.message
    }

    var syncRun: SyncRun {
        SyncRun(
            id: UUID(uuidString: id)!,
            accountID: UUID(uuidString: accountID)!,
            providerID: ProviderID(rawValue: providerID)!,
            startedAt: startedAt,
            finishedAt: finishedAt,
            status: SyncRun.Status(rawValue: status)!,
            message: message
        )
    }
}

private struct AccountSyncStateRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.accountSyncStates

    var accountID: String
    var providerID: String
    var supportsUsage: Bool
    var supportsActualCost: Bool
    var supportsResetDate: Bool
    var supportsModelBreakdown: Bool
    var quality: String
    var message: String?
    var billingStartsAt: Date?
    var billingEndsAt: Date?
    var billingResetAt: Date?
    var updatedAt: Date

    init(result: ProviderSyncResult, updatedAt: Date) {
        accountID = result.accountID.uuidString
        providerID = result.providerID.rawValue
        supportsUsage = result.capabilities.supportsUsage
        supportsActualCost = result.capabilities.supportsActualCost
        supportsResetDate = result.capabilities.supportsResetDate
        supportsModelBreakdown = result.capabilities.supportsModelBreakdown
        quality = result.capabilities.dataQuality.rawValue
        message = result.capabilities.message
        billingStartsAt = result.billingPeriod?.startsAt
        billingEndsAt = result.billingPeriod?.endsAt
        billingResetAt = result.billingPeriod?.resetAt
        self.updatedAt = updatedAt
    }

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportsUsage: supportsUsage,
            supportsActualCost: supportsActualCost,
            supportsResetDate: supportsResetDate,
            supportsModelBreakdown: supportsModelBreakdown,
            dataQuality: DataQuality(rawValue: quality)!,
            message: message
        )
    }

    var billingPeriod: BillingPeriod? {
        guard billingStartsAt != nil || billingEndsAt != nil || billingResetAt != nil else {
            return nil
        }

        return BillingPeriod(
            startsAt: billingStartsAt ?? updatedAt,
            endsAt: billingEndsAt,
            resetAt: billingResetAt
        )
    }
}

private struct SyncWatermarkRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.syncWatermarks

    var sourceKey: String
    var accountID: String
    var fileSize: Int64
    var fileMTime: Date
    var byteOffset: Int64
    var updatedAt: Date

    init(_ watermark: SyncWatermark) {
        sourceKey = watermark.sourceKey
        accountID = watermark.accountID.uuidString
        fileSize = watermark.fileSize
        fileMTime = watermark.fileMTime
        byteOffset = watermark.byteOffset
        updatedAt = watermark.updatedAt
    }

    var watermark: SyncWatermark {
        SyncWatermark(
            sourceKey: sourceKey,
            accountID: UUID(uuidString: accountID)!,
            fileSize: fileSize,
            fileMTime: fileMTime,
            byteOffset: byteOffset,
            updatedAt: updatedAt
        )
    }
}

private struct RateWindowSampleRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.rateWindowSamples

    var id: String
    var accountID: String
    var kind: String
    var observedAt: Date
    var usedFraction: Double?
    var resetAt: Date

    init(_ window: RateWindow, accountID: UUID) {
        // A fresh UUID per observation, unlike the snapshot tables where
        // SnapshotIdentity derives a stable key so a re-read replaces its row.
        // Here every row is a distinct observation that must never replace
        // another; the natural key is (accountID, kind, observedAt).
        id = UUID().uuidString
        self.accountID = accountID.uuidString
        kind = window.kind.rawValue
        observedAt = window.observedAt
        usedFraction = window.usedFraction
        resetAt = window.resetAt
    }

    var window: RateWindow? {
        guard let kind = RateWindowKind(rawValue: kind) else { return nil }
        return RateWindow(
            kind: kind,
            usedFraction: usedFraction,
            resetAt: resetAt,
            observedAt: observedAt
        )
    }
}

final class LedgerStore {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func saveAccount(_ account: Account) throws {
        let record = AccountRecord(account)

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(LedgerTable.accounts) (
                        \(LedgerColumn.id),
                        \(LedgerColumn.providerID),
                        \(LedgerColumn.displayName),
                        \(LedgerColumn.credentialReference),
                        \(LedgerColumn.createdAt),
                        \(LedgerColumn.isEnabled)
                    )
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(\(LedgerColumn.id)) DO UPDATE SET
                        \(LedgerColumn.providerID) = excluded.\(LedgerColumn.providerID),
                        \(LedgerColumn.displayName) = excluded.\(LedgerColumn.displayName),
                        \(LedgerColumn.credentialReference) = excluded.\(LedgerColumn.credentialReference),
                        \(LedgerColumn.createdAt) = excluded.\(LedgerColumn.createdAt),
                        \(LedgerColumn.isEnabled) = excluded.\(LedgerColumn.isEnabled)
                    """,
                arguments: [
                    record.id,
                    record.providerID,
                    record.displayName,
                    record.credentialReference,
                    record.createdAt,
                    record.isEnabled,
                ]
            )
        }
    }

    func fetchAccounts() throws -> [Account] {
        try dbQueue.read { db in
            try AccountRecord
                .order(Column(LedgerColumn.createdAt), Column(LedgerColumn.id))
                .fetchAll(db)
                .map(\.account)
        }
    }

    func upsertUsageSnapshots(_ snapshots: [UsageSnapshot]) throws {
        try dbQueue.write { db in
            try Self.upsertUsageSnapshots(snapshots, db: db)
        }
    }

    func upsertCostSnapshots(_ snapshots: [CostSnapshot]) throws {
        try dbQueue.write { db in
            try Self.upsertCostSnapshots(snapshots, db: db)
        }
    }

    func upsertEstimateSnapshots(_ snapshots: [EstimateSnapshot]) throws {
        try dbQueue.write { db in
            try Self.upsertEstimateSnapshots(snapshots, db: db)
        }
    }

    func startSyncRun(accountID: UUID, providerID: ProviderID, startedAt: Date) throws -> UUID {
        let syncRun = SyncRun(
            id: UUID(),
            accountID: accountID,
            providerID: providerID,
            startedAt: startedAt,
            finishedAt: nil,
            status: .running,
            message: nil
        )
        let record = SyncRunRecord(syncRun)

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(LedgerTable.syncRuns) (
                        \(LedgerColumn.id),
                        \(LedgerColumn.accountID),
                        \(LedgerColumn.providerID),
                        \(LedgerColumn.startedAt),
                        \(LedgerColumn.finishedAt),
                        \(LedgerColumn.status),
                        \(LedgerColumn.message)
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id,
                    record.accountID,
                    record.providerID,
                    record.startedAt,
                    record.finishedAt,
                    record.status,
                    record.message,
                ]
            )
        }

        return syncRun.id
    }

    func finishSyncRun(
        id: UUID,
        status: SyncRun.Status,
        message: String?,
        finishedAt: Date
    ) throws {
        try dbQueue.write { db in
            try Self.finishSyncRun(
                id: id,
                status: status,
                message: message,
                finishedAt: finishedAt,
                db: db
            )
        }
    }

    func applySuccessfulSyncResult(
        _ result: ProviderSyncResult,
        syncRunID: UUID,
        finishedAt: Date
    ) throws {
        try dbQueue.write { db in
            try Self.upsertUsageSnapshots(result.usageSnapshots, db: db)
            try Self.upsertCostSnapshots(result.costSnapshots, db: db)
            try Self.upsertEstimateSnapshots(result.estimateSnapshots, db: db)
            try Self.upsertAccountSyncState(result, updatedAt: finishedAt, db: db)
            try Self.finishSyncRun(
                id: syncRunID,
                status: .succeeded,
                message: nil,
                finishedAt: finishedAt,
                db: db
            )
        }
    }

    func fetchUsageSnapshots(accountID: UUID) throws -> [UsageSnapshot] {
        try dbQueue.read { db in
            try UsageSnapshotRecord
                .filter(Column(LedgerColumn.accountID) == accountID.uuidString)
                .order(
                    Column(LedgerColumn.bucketStart),
                    Column(LedgerColumn.bucketEnd),
                    Column(LedgerColumn.modelKey)
                )
                .fetchAll(db)
                .map(\.snapshot)
        }
    }

    func fetchCostSnapshots(accountID: UUID) throws -> [CostSnapshot] {
        try dbQueue.read { db in
            try CostSnapshotRecord
                .filter(Column(LedgerColumn.accountID) == accountID.uuidString)
                .order(
                    Column(LedgerColumn.bucketStart),
                    Column(LedgerColumn.bucketEnd),
                    Column(LedgerColumn.currency)
                )
                .fetchAll(db)
                .map(\.snapshot)
        }
    }

    func fetchEstimateSnapshots(accountID: UUID) throws -> [EstimateSnapshot] {
        try dbQueue.read { db in
            try EstimateSnapshotRecord
                .filter(Column(LedgerColumn.accountID) == accountID.uuidString)
                .order(
                    Column(LedgerColumn.bucketStart),
                    Column(LedgerColumn.bucketEnd),
                    Column(LedgerColumn.currency)
                )
                .fetchAll(db)
                .map(\.snapshot)
        }
    }

    func fetchSyncRuns(accountID: UUID) throws -> [SyncRun] {
        try dbQueue.read { db in
            try SyncRunRecord
                .filter(Column(LedgerColumn.accountID) == accountID.uuidString)
                .order(Column(LedgerColumn.startedAt), Column(LedgerColumn.id))
                .fetchAll(db)
                .map(\.syncRun)
        }
    }

    func fetchDailySummaries(accountID: UUID) throws -> [DailyUsageSummary] {
        try dbQueue.read { db in
            let usageSnapshots = try UsageSnapshotRecord
                .filter(Column(LedgerColumn.accountID) == accountID.uuidString)
                .fetchAll(db)
                .map(\.snapshot)
            let estimateSnapshots = try EstimateSnapshotRecord
                .filter(Column(LedgerColumn.accountID) == accountID.uuidString)
                .fetchAll(db)
                .map(\.snapshot)

            var summariesByDay: [Date: DailyUsageAccumulator] = [:]

            for snapshot in usageSnapshots {
                let dayStart = DailySummaryCalendar.utc.startOfDay(for: snapshot.bucketStart)
                var accumulator = summariesByDay[dayStart] ?? DailyUsageAccumulator(
                    accountID: accountID,
                    dayStart: dayStart
                )
                accumulator.add(snapshot)
                summariesByDay[dayStart] = accumulator
            }

            for snapshot in estimateSnapshots {
                let dayStart = DailySummaryCalendar.utc.startOfDay(for: snapshot.bucketStart)
                var accumulator = summariesByDay[dayStart] ?? DailyUsageAccumulator(
                    accountID: accountID,
                    dayStart: dayStart
                )
                accumulator.add(snapshot)
                summariesByDay[dayStart] = accumulator
            }

            return summariesByDay.values
                .map { $0.summary() }
                .sorted {
                    if $0.dayStart == $1.dayStart {
                        return $0.accountID.uuidString < $1.accountID.uuidString
                    }

                    return $0.dayStart > $1.dayStart
                }
        }
    }

    func fetchAccountSummaries() throws -> [AccountUsageSummary] {
        try dbQueue.read { db in
            let accounts = try AccountRecord
                .order(Column(LedgerColumn.createdAt), Column(LedgerColumn.id))
                .fetchAll(db)
                .map(\.account)

            return try accounts.map { account in
                let accountID = account.id.uuidString
                let usageSnapshots = try UsageSnapshotRecord
                    .filter(Column(LedgerColumn.accountID) == accountID)
                    .fetchAll(db)
                    .map(\.snapshot)
                let costSnapshots = try CostSnapshotRecord
                    .filter(Column(LedgerColumn.accountID) == accountID)
                    .fetchAll(db)
                    .map(\.snapshot)
                let estimateSnapshots = try EstimateSnapshotRecord
                    .filter(Column(LedgerColumn.accountID) == accountID)
                    .fetchAll(db)
                    .map(\.snapshot)
                let state = try AccountSyncStateRecord
                    .filter(Column(LedgerColumn.accountID) == accountID)
                    .fetchOne(db)
                let latestSyncRun = try SyncRunRecord
                    .filter(Column(LedgerColumn.accountID) == accountID)
                    .order(Column(LedgerColumn.startedAt).desc, Column(LedgerColumn.id).desc)
                    .fetchOne(db)?
                    .syncRun

                return Self.makeAccountSummary(
                    account: account,
                    state: state,
                    latestSyncRun: latestSyncRun,
                    usageSnapshots: usageSnapshots,
                    costSnapshots: costSnapshots,
                    estimateSnapshots: estimateSnapshots
                )
            }
        }
    }

    func fetchWatermark(sourceKey: String) throws -> SyncWatermark? {
        try dbQueue.read { db in
            try SyncWatermarkRecord
                .filter(Column(LedgerColumn.sourceKey) == sourceKey)
                .fetchOne(db)?
                .watermark
        }
    }

    func saveWatermark(_ watermark: SyncWatermark) throws {
        let record = SyncWatermarkRecord(watermark)

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(LedgerTable.syncWatermarks) (
                        \(LedgerColumn.sourceKey),
                        \(LedgerColumn.accountID),
                        \(LedgerColumn.fileSize),
                        \(LedgerColumn.fileMTime),
                        \(LedgerColumn.byteOffset),
                        \(LedgerColumn.updatedAt)
                    )
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(\(LedgerColumn.sourceKey)) DO UPDATE SET
                        \(LedgerColumn.accountID) = excluded.\(LedgerColumn.accountID),
                        \(LedgerColumn.fileSize) = excluded.\(LedgerColumn.fileSize),
                        \(LedgerColumn.fileMTime) = excluded.\(LedgerColumn.fileMTime),
                        \(LedgerColumn.byteOffset) = excluded.\(LedgerColumn.byteOffset),
                        \(LedgerColumn.updatedAt) = excluded.\(LedgerColumn.updatedAt)
                    """,
                arguments: [
                    record.sourceKey,
                    record.accountID,
                    record.fileSize,
                    record.fileMTime,
                    record.byteOffset,
                    record.updatedAt,
                ]
            )
        }
    }

    func fetchBackfillCompletedThrough(accountID: UUID) throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(
                db,
                sql: """
                    SELECT \(LedgerColumn.backfillCompletedThrough)
                    FROM \(LedgerTable.accountSyncStates)
                    WHERE \(LedgerColumn.accountID) = ?
                    """,
                arguments: [accountID.uuidString]
            )
        }
    }

    /// Records how far back backfill has walked for an account.
    ///
    /// An upsert rather than a bare `UPDATE`: an account that has not yet completed
    /// a sync has no `accountSyncStates` row, and an `UPDATE` would then match
    /// nothing and silently succeed, losing the watermark so backfill restarts from
    /// scratch forever with no error anywhere.
    ///
    /// The synthesised row claims nothing it does not know: no capabilities and
    /// `unavailable` quality, which is the truth until a sync reports otherwise.
    /// `upsertAccountSyncState` overwrites every one of those columns on the next
    /// sync and deliberately leaves `backfillCompletedThrough` alone, so the two
    /// writers do not fight.
    func saveBackfillCompletedThrough(_ day: Date, accountID: UUID) throws {
        try dbQueue.write { db in
            guard let providerID = try String.fetchOne(
                db,
                sql: """
                    SELECT \(LedgerColumn.providerID)
                    FROM \(LedgerTable.accounts)
                    WHERE \(LedgerColumn.id) = ?
                    """,
                arguments: [accountID.uuidString]
            ) else {
                throw LedgerStoreError.unknownAccount
            }

            try db.execute(
                sql: """
                    INSERT INTO \(LedgerTable.accountSyncStates) (
                        \(LedgerColumn.accountID),
                        \(LedgerColumn.providerID),
                        \(LedgerColumn.supportsUsage),
                        \(LedgerColumn.supportsActualCost),
                        \(LedgerColumn.supportsResetDate),
                        \(LedgerColumn.supportsModelBreakdown),
                        \(LedgerColumn.quality),
                        \(LedgerColumn.updatedAt),
                        \(LedgerColumn.backfillCompletedThrough)
                    )
                    VALUES (?, ?, 0, 0, 0, 0, ?, ?, ?)
                    ON CONFLICT(\(LedgerColumn.accountID)) DO UPDATE SET
                        \(LedgerColumn.backfillCompletedThrough) = excluded.\(LedgerColumn.backfillCompletedThrough)
                    """,
                arguments: [
                    accountID.uuidString,
                    providerID,
                    DataQuality.unavailable.rawValue,
                    Date(),
                    day,
                ]
            )
        }
    }

    /// Appends an observation, but only when it differs from the newest one for
    /// the same account and kind. A window moves stepwise, so dropping repeats
    /// is lossless and takes the yearly volume from ~500k rows to ~15k.
    ///
    /// Implausible observations are discarded rather than stored.
    func saveRateWindow(_ window: RateWindow, accountID: UUID) throws {
        guard window.isPlausible(now: window.observedAt) else { return }

        try dbQueue.write { db in
            let newest = try RateWindowSampleRecord
                .filter(Column(LedgerColumn.accountID) == accountID.uuidString)
                .filter(Column(LedgerColumn.kind) == window.kind.rawValue)
                .order(Column(LedgerColumn.observedAt).desc)
                .fetchOne(db)

            if let newest,
               newest.usedFraction == window.usedFraction,
               newest.resetAt == window.resetAt {
                return
            }

            try RateWindowSampleRecord(window, accountID: accountID).insert(db)
        }
    }

    /// The newest observation for each kind this account has ever reported.
    func fetchLatestRateWindows(accountID: UUID) throws -> [RateWindow] {
        try dbQueue.read { db in
            try RateWindowKind.allCases.compactMap { kind in
                try RateWindowSampleRecord
                    .filter(Column(LedgerColumn.accountID) == accountID.uuidString)
                    .filter(Column(LedgerColumn.kind) == kind.rawValue)
                    .order(Column(LedgerColumn.observedAt).desc)
                    .fetchOne(db)?
                    .window
            }
        }
    }

    /// Retention. Runs on every tick, including ticks where every fetch failed —
    /// otherwise the table grows precisely when nobody is watching.
    func deleteRateWindowSamples(olderThan cutoff: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM \(LedgerTable.rateWindowSamples) WHERE \(LedgerColumn.observedAt) < ?",
                arguments: [cutoff]
            )
        }
    }

    private static func upsertUsageSnapshots(_ snapshots: [UsageSnapshot], db: Database) throws {
        guard !snapshots.isEmpty else {
            return
        }

        for snapshot in snapshots {
            let record = UsageSnapshotRecord(snapshot)
            try db.execute(
                sql: """
                    INSERT INTO \(LedgerTable.usageSnapshots) (
                        \(LedgerColumn.id),
                        \(LedgerColumn.accountID),
                        \(LedgerColumn.providerID),
                        \(LedgerColumn.bucketStart),
                        \(LedgerColumn.bucketEnd),
                        \(LedgerColumn.model),
                        \(LedgerColumn.modelKey),
                        \(LedgerColumn.inputTokens),
                        \(LedgerColumn.cacheCreationTokens),
                        \(LedgerColumn.cacheReadTokens),
                        \(LedgerColumn.outputTokens),
                        \(LedgerColumn.requests),
                        \(LedgerColumn.quality)
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(
                        \(LedgerColumn.accountID),
                        \(LedgerColumn.providerID),
                        \(LedgerColumn.bucketStart),
                        \(LedgerColumn.bucketEnd),
                        \(LedgerColumn.modelKey)
                    ) DO UPDATE SET
                        \(LedgerColumn.id) = excluded.\(LedgerColumn.id),
                        \(LedgerColumn.model) = excluded.\(LedgerColumn.model),
                        \(LedgerColumn.inputTokens) = excluded.\(LedgerColumn.inputTokens),
                        \(LedgerColumn.cacheCreationTokens) = excluded.\(LedgerColumn.cacheCreationTokens),
                        \(LedgerColumn.cacheReadTokens) = excluded.\(LedgerColumn.cacheReadTokens),
                        \(LedgerColumn.outputTokens) = excluded.\(LedgerColumn.outputTokens),
                        \(LedgerColumn.requests) = excluded.\(LedgerColumn.requests),
                        \(LedgerColumn.quality) = excluded.\(LedgerColumn.quality)
                    """,
                arguments: [
                    record.id,
                    record.accountID,
                    record.providerID,
                    record.bucketStart,
                    record.bucketEnd,
                    record.model,
                    record.modelKey,
                    record.inputTokens,
                    record.cacheCreationTokens,
                    record.cacheReadTokens,
                    record.outputTokens,
                    record.requests,
                    record.quality,
                ]
            )
        }
    }

    private static func upsertCostSnapshots(_ snapshots: [CostSnapshot], db: Database) throws {
        guard !snapshots.isEmpty else {
            return
        }

        for snapshot in snapshots {
            let record = CostSnapshotRecord(snapshot)
            try db.execute(
                sql: """
                    INSERT INTO \(LedgerTable.costSnapshots) (
                        \(LedgerColumn.id),
                        \(LedgerColumn.accountID),
                        \(LedgerColumn.providerID),
                        \(LedgerColumn.bucketStart),
                        \(LedgerColumn.bucketEnd),
                        \(LedgerColumn.amountMicros),
                        \(LedgerColumn.currency),
                        \(LedgerColumn.quality)
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(
                        \(LedgerColumn.accountID),
                        \(LedgerColumn.providerID),
                        \(LedgerColumn.bucketStart),
                        \(LedgerColumn.bucketEnd),
                        \(LedgerColumn.currency)
                    ) DO UPDATE SET
                        \(LedgerColumn.id) = excluded.\(LedgerColumn.id),
                        \(LedgerColumn.amountMicros) = excluded.\(LedgerColumn.amountMicros),
                        \(LedgerColumn.quality) = excluded.\(LedgerColumn.quality)
                    """,
                arguments: [
                    record.id,
                    record.accountID,
                    record.providerID,
                    record.bucketStart,
                    record.bucketEnd,
                    record.amountMicros,
                    record.currency,
                    record.quality,
                ]
            )
        }
    }

    private static func upsertEstimateSnapshots(_ snapshots: [EstimateSnapshot], db: Database) throws {
        guard !snapshots.isEmpty else {
            return
        }

        for snapshot in snapshots {
            let record = EstimateSnapshotRecord(snapshot)
            try db.execute(
                sql: """
                    INSERT INTO \(LedgerTable.estimateSnapshots) (
                        \(LedgerColumn.id),
                        \(LedgerColumn.accountID),
                        \(LedgerColumn.providerID),
                        \(LedgerColumn.bucketStart),
                        \(LedgerColumn.bucketEnd),
                        \(LedgerColumn.estimatedAmountMicros),
                        \(LedgerColumn.currency),
                        \(LedgerColumn.quality)
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(
                        \(LedgerColumn.accountID),
                        \(LedgerColumn.providerID),
                        \(LedgerColumn.bucketStart),
                        \(LedgerColumn.bucketEnd),
                        \(LedgerColumn.currency)
                    ) DO UPDATE SET
                        \(LedgerColumn.id) = excluded.\(LedgerColumn.id),
                        \(LedgerColumn.estimatedAmountMicros) = excluded.\(LedgerColumn.estimatedAmountMicros),
                        \(LedgerColumn.quality) = excluded.\(LedgerColumn.quality)
                    """,
                arguments: [
                    record.id,
                    record.accountID,
                    record.providerID,
                    record.bucketStart,
                    record.bucketEnd,
                    record.estimatedAmountMicros,
                    record.currency,
                    record.quality,
                ]
            )
        }
    }

    /// Persists the capabilities and billing period a sync reported.
    ///
    /// The three billing columns are `COALESCE`d rather than assigned, because a
    /// result carrying no billing period means "this sync did not learn one", not
    /// "this account has none". Backfill makes the difference load-bearing: a scoped
    /// adapter returns `billingPeriod: nil` on purpose — a historic week is not a
    /// billing period — and a plain `= excluded.…` would let each of the ~53 slices
    /// NULL out the true period phase one had just written, so the reset date would
    /// vanish from the UI until the next routine sync.
    ///
    /// The cost is that the three billing columns can go stale: they outlive the sync
    /// that wrote them, and nothing here can tell "no period reported this time" from
    /// "no period any more". Only `supportsResetDate`, which *is* assigned
    /// unconditionally, carries that distinction, so it — not these columns — is what
    /// decides whether a reset date may be shown. `AccountSummaryFormatting.billing`
    /// is where that reading happens.
    private static func upsertAccountSyncState(
        _ result: ProviderSyncResult,
        updatedAt: Date,
        db: Database
    ) throws {
        let record = AccountSyncStateRecord(result: result, updatedAt: updatedAt)
        try db.execute(
            sql: """
                INSERT INTO \(LedgerTable.accountSyncStates) (
                    \(LedgerColumn.accountID),
                    \(LedgerColumn.providerID),
                    \(LedgerColumn.supportsUsage),
                    \(LedgerColumn.supportsActualCost),
                    \(LedgerColumn.supportsResetDate),
                    \(LedgerColumn.supportsModelBreakdown),
                    \(LedgerColumn.quality),
                    \(LedgerColumn.message),
                    \(LedgerColumn.billingStartsAt),
                    \(LedgerColumn.billingEndsAt),
                    \(LedgerColumn.billingResetAt),
                    \(LedgerColumn.updatedAt)
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(\(LedgerColumn.accountID)) DO UPDATE SET
                    \(LedgerColumn.providerID) = excluded.\(LedgerColumn.providerID),
                    \(LedgerColumn.supportsUsage) = excluded.\(LedgerColumn.supportsUsage),
                    \(LedgerColumn.supportsActualCost) = excluded.\(LedgerColumn.supportsActualCost),
                    \(LedgerColumn.supportsResetDate) = excluded.\(LedgerColumn.supportsResetDate),
                    \(LedgerColumn.supportsModelBreakdown) = excluded.\(LedgerColumn.supportsModelBreakdown),
                    \(LedgerColumn.quality) = excluded.\(LedgerColumn.quality),
                    \(LedgerColumn.message) = excluded.\(LedgerColumn.message),
                    \(LedgerColumn.billingStartsAt) = COALESCE(
                        excluded.\(LedgerColumn.billingStartsAt),
                        \(LedgerColumn.billingStartsAt)
                    ),
                    \(LedgerColumn.billingEndsAt) = COALESCE(
                        excluded.\(LedgerColumn.billingEndsAt),
                        \(LedgerColumn.billingEndsAt)
                    ),
                    \(LedgerColumn.billingResetAt) = COALESCE(
                        excluded.\(LedgerColumn.billingResetAt),
                        \(LedgerColumn.billingResetAt)
                    ),
                    \(LedgerColumn.updatedAt) = excluded.\(LedgerColumn.updatedAt)
                """,
            arguments: [
                record.accountID,
                record.providerID,
                record.supportsUsage,
                record.supportsActualCost,
                record.supportsResetDate,
                record.supportsModelBreakdown,
                record.quality,
                record.message,
                record.billingStartsAt,
                record.billingEndsAt,
                record.billingResetAt,
                record.updatedAt,
            ]
        )
    }

    private static func finishSyncRun(
        id: UUID,
        status: SyncRun.Status,
        message: String?,
        finishedAt: Date,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE \(LedgerTable.syncRuns)
                SET
                    \(LedgerColumn.finishedAt) = ?,
                    \(LedgerColumn.status) = ?,
                    \(LedgerColumn.message) = ?
                WHERE \(LedgerColumn.id) = ?
                """,
            arguments: [
                finishedAt,
                status.rawValue,
                message,
                id.uuidString,
            ]
        )
    }

    private static func makeAccountSummary(
        account: Account,
        state: AccountSyncStateRecord?,
        latestSyncRun: SyncRun?,
        usageSnapshots: [UsageSnapshot],
        costSnapshots: [CostSnapshot],
        estimateSnapshots: [EstimateSnapshot]
    ) -> AccountUsageSummary {
        let inputTokens = usageSnapshots.reduce(Int64(0)) { $0 + $1.inputTokens }
        let cacheCreationTokens = usageSnapshots.reduce(Int64(0)) { $0 + $1.cacheCreationTokens }
        let cacheReadTokens = usageSnapshots.reduce(Int64(0)) { $0 + $1.cacheReadTokens }
        let outputTokens = usageSnapshots.reduce(Int64(0)) { $0 + $1.outputTokens }

        // Nil unless at least one snapshot reported a request count. Snapshots
        // without one are skipped rather than counted as a measured zero.
        let requests = usageSnapshots.reduce(nil) { partial, snapshot -> Int64? in
            guard let snapshotRequests = snapshot.requests else {
                return partial
            }

            return (partial ?? 0) + snapshotRequests
        }

        var actualTotal = SnapshotMoneyTotal()
        for snapshot in costSnapshots {
            actualTotal.add(
                amountMicros: snapshot.amountMicros,
                currency: snapshot.currency,
                quality: snapshot.quality
            )
        }

        var estimateTotal = SnapshotMoneyTotal()
        for snapshot in estimateSnapshots {
            estimateTotal.add(
                amountMicros: snapshot.estimatedAmountMicros,
                currency: snapshot.currency,
                quality: snapshot.quality
            )
        }

        let quality = state?.capabilities.dataQuality
            ?? worstQuality(
                usageSnapshots.map(\.quality)
                    + costSnapshots.map(\.quality)
                    + estimateSnapshots.map(\.quality)
            )
            ?? .unavailable

        return AccountUsageSummary(
            account: account,
            capabilities: state?.capabilities,
            billingPeriod: state?.billingPeriod,
            latestSyncRun: latestSyncRun,
            inputTokens: inputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            requestCount: requests,
            actualAmountMicros: actualTotal.amountMicros,
            estimatedAmountMicros: estimateTotal.amountMicros,
            displayCurrency: actualTotal.currency ?? estimateTotal.currency,
            dataQuality: quality
        )
    }

    private static func worstQuality(_ qualities: [DataQuality]) -> DataQuality? {
        qualities.max { lhs, rhs in
            lhs.isBetterThan(rhs)
        }
    }
}

/// Safe because every access goes through *this instance's* GRDB `DatabaseQueue`,
/// which serializes the reads and writes made through it.
///
/// That is all this extension asserts. It says nothing about access from another
/// connection: the app opens one queue per scene on the same file, so two
/// `LedgerStore`s can be writing and reading concurrently. Safety *between*
/// connections is SQLite's, and rests on the WAL journal mode and busy timeout
/// `DatabaseQueueFactory.makeConfiguration` sets — not on this line.
extension LedgerStore: @unchecked Sendable {}
