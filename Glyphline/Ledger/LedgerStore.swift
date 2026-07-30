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

/// A machine-wide daily total for one model, read from the local Claude Code
/// transcripts.
///
/// Deliberately account-free: the transcripts carry no marker of which
/// subscription was active, so these totals are the sum across all of them and
/// must not pretend otherwise.
///
/// A write is a *delta*, not a state. Transcripts are read incrementally, so the
/// same `(bucketStart, modelKey)` is written repeatedly with only the newly-read
/// tokens; the store adds it to what is already there.
struct LocalTokenUsage: Equatable, Sendable {
    /// Start of the UTC day this total belongs to.
    var bucketStart: Date
    var model: String?
    var inputTokens: Int64 = 0
    var cacheCreationTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var requests: Int64 = 0

    /// Stable key for a possibly-absent model name, so an unnamed model gets one
    /// row rather than colliding on NULL.
    var modelKey: String { LedgerModelIdentity.makeKey(for: model) }

    var totalTokens: Int64 {
        inputTokens + cacheCreationTokens + cacheReadTokens + outputTokens
    }
}

/// Resume point for the machine-wide transcript scan. `SyncWatermark` minus its
/// account, because the scan has none.
struct LocalScanWatermark: Equatable, Sendable {
    /// Stable identifier for the source. For local logs, the file path.
    var sourceKey: String
    var fileSize: Int64
    var fileMTime: Date
    var byteOffset: Int64
    var updatedAt: Date
}

/// A session sitting in the pit lane: it was on the map, then went quiet for
/// longer than the horizon.
///
/// `lastActivityAt` is kept alongside `parkedAt` because they answer different
/// questions — how long since it did anything, versus how long until it expires.
struct ParkedAgentSession: Identifiable, Equatable, Sendable {
    var sessionID: String
    var cwd: String
    var gitBranch: String?
    var subagentCount: Int
    var lastActivityAt: Date
    var parkedAt: Date

    var id: String { sessionID }
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

/// What a deletion would destroy, counted from the ledger so the confirmation
/// dialog can name real numbers instead of a generic warning.
struct AccountDeletionSummary: Equatable, Sendable {
    var rateWindowSampleCount: Int
    var earliestRateWindowObservedAt: Date?
    var costSnapshotCount: Int
    var usageSnapshotCount: Int

    /// What the confirmation shows when the counts cannot be read. Understating
    /// the loss is the wrong failure here, but the alternative — refusing to
    /// open the dialog — leaves the user unable to delete anything at all.
    static let empty = AccountDeletionSummary(
        rateWindowSampleCount: 0,
        earliestRateWindowObservedAt: nil,
        costSnapshotCount: 0,
        usageSnapshotCount: 0
    )
}

private struct AccountRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.accounts

    var id: String
    var providerID: String
    var displayName: String
    var credentialReference: String
    var createdAt: Date
    var isEnabled: Bool
    var quotaCredentialReference: String?
    var claudeOrganizationID: String?

    init(_ account: Account) {
        id = account.id.uuidString
        providerID = account.providerID.rawValue
        displayName = account.displayName
        credentialReference = account.credentialReference
        createdAt = account.createdAt
        isEnabled = account.isEnabled
        quotaCredentialReference = account.quotaCredentialReference
        claudeOrganizationID = account.claudeOrganizationID
    }

    var account: Account {
        Account(
            id: UUID(uuidString: id)!,
            providerID: ProviderID(rawValue: providerID)!,
            displayName: displayName,
            credentialReference: credentialReference,
            createdAt: createdAt,
            isEnabled: isEnabled,
            quotaCredentialReference: quotaCredentialReference,
            claudeOrganizationID: claudeOrganizationID
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

private struct LocalTokenUsageRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.localTokenUsage

    var bucketStart: Date
    var modelKey: String
    var model: String?
    var inputTokens: Int64
    var cacheCreationTokens: Int64
    var cacheReadTokens: Int64
    var outputTokens: Int64
    var requests: Int64

    var usage: LocalTokenUsage {
        LocalTokenUsage(
            bucketStart: bucketStart,
            model: model,
            inputTokens: inputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            requests: requests
        )
    }
}

private struct LocalScanWatermarkRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.localScanWatermarks

    var sourceKey: String
    var fileSize: Int64
    var fileMTime: Date
    var byteOffset: Int64
    var updatedAt: Date

    init(_ watermark: LocalScanWatermark) {
        sourceKey = watermark.sourceKey
        fileSize = watermark.fileSize
        fileMTime = watermark.fileMTime
        byteOffset = watermark.byteOffset
        updatedAt = watermark.updatedAt
    }

    var watermark: LocalScanWatermark {
        LocalScanWatermark(
            sourceKey: sourceKey,
            fileSize: fileSize,
            fileMTime: fileMTime,
            byteOffset: byteOffset,
            updatedAt: updatedAt
        )
    }
}

private struct ParkedAgentRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.agentverseParked

    var sessionID: String
    var cwd: String
    var gitBranch: String?
    var subagentCount: Int
    var lastActivityAt: Date
    var parkedAt: Date

    init(_ session: ParkedAgentSession) {
        sessionID = session.sessionID
        cwd = session.cwd
        gitBranch = session.gitBranch
        subagentCount = session.subagentCount
        lastActivityAt = session.lastActivityAt
        parkedAt = session.parkedAt
    }

    var session: ParkedAgentSession {
        ParkedAgentSession(
            sessionID: sessionID,
            cwd: cwd,
            gitBranch: gitBranch,
            subagentCount: subagentCount,
            lastActivityAt: lastActivityAt,
            parkedAt: parkedAt
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
    /// Nullable since v8: a window with no active reset is a state worth
    /// storing, not a row to discard.
    var resetAt: Date?

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
    /// Just above GRDB's millisecond storage resolution.
    private static let resetAtStorageTolerance: TimeInterval = 0.002

    /// Whether two reset instants are the same *as stored*.
    ///
    /// GRDB stores `Date` at millisecond resolution, so an instant carrying
    /// finer precision never compares equal to its own round trip; an exact
    /// comparison would append a row on every poll. The bound is just above the
    /// storage error, not a semantic tolerance — a reset genuinely moving is
    /// always far larger.
    ///
    /// Nil is a value here, not a wildcard: two windows with no active reset are
    /// the same reading, and a window gaining or losing its reset is a genuine
    /// change that must be recorded. Getting either half wrong is silent — one
    /// way writes a duplicate row on every poll, the other drops a real
    /// transition — which is why this is a named function with its own tests
    /// rather than an expression inside the dedupe.
    static func isSameStoredReset(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSince(rhs)) < resetAtStorageTolerance
        default:
            return false
        }
    }

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
                        \(LedgerColumn.isEnabled),
                        \(LedgerColumn.quotaCredentialReference),
                        \(LedgerColumn.claudeOrganizationID)
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(\(LedgerColumn.id)) DO UPDATE SET
                        \(LedgerColumn.providerID) = excluded.\(LedgerColumn.providerID),
                        \(LedgerColumn.displayName) = excluded.\(LedgerColumn.displayName),
                        \(LedgerColumn.credentialReference) = excluded.\(LedgerColumn.credentialReference),
                        \(LedgerColumn.createdAt) = excluded.\(LedgerColumn.createdAt),
                        \(LedgerColumn.isEnabled) = excluded.\(LedgerColumn.isEnabled),
                        \(LedgerColumn.quotaCredentialReference) = excluded.\(LedgerColumn.quotaCredentialReference),
                        \(LedgerColumn.claudeOrganizationID) = excluded.\(LedgerColumn.claudeOrganizationID)
                    """,
                arguments: [
                    record.id,
                    record.providerID,
                    record.displayName,
                    record.credentialReference,
                    record.createdAt,
                    record.isEnabled,
                    record.quotaCredentialReference,
                    record.claudeOrganizationID,
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

    /// Adds the given deltas to the machine-wide daily per-model totals.
    ///
    /// **This accumulates; it does not replace.** A transcript is read
    /// incrementally, so the same `(bucketStart, modelKey)` arrives again and
    /// again carrying only the tokens read since the last write. Turning any of
    /// these clauses into `= excluded.column` silently destroys everything
    /// accumulated for that day and model — a defect this project has shipped
    /// three times.
    func upsertLocalTokenUsage(_ rows: [LocalTokenUsage]) throws {
        guard !rows.isEmpty else { return }

        try dbQueue.write { db in
            try Self.addLocalTokenUsage(rows, in: db)
        }
    }

    /// Persists one local scan: its token deltas and the resume points that
    /// consume them, in a single transaction.
    ///
    /// The scan emits deltas, so the two halves cannot be split. If the tokens
    /// landed but the watermarks did not, the next scan would read those bytes
    /// again and double-count them; if the watermarks landed but the tokens did
    /// not, those bytes are never read again and the totals understate for good.
    /// One transaction: both, or neither.
    func applyLocalScan(usage: [LocalTokenUsage], watermarks: [LocalScanWatermark]) throws {
        guard !usage.isEmpty || !watermarks.isEmpty else { return }

        try dbQueue.write { db in
            try Self.addLocalTokenUsage(usage, in: db)
            for watermark in watermarks {
                try Self.saveLocalScanWatermark(watermark, in: db)
            }
        }
    }

    private static func addLocalTokenUsage(_ rows: [LocalTokenUsage], in db: Database) throws {
        for row in rows {
            try db.execute(
                sql: """
                    INSERT INTO \(LedgerTable.localTokenUsage) (
                        \(LedgerColumn.bucketStart),
                        \(LedgerColumn.modelKey),
                        \(LedgerColumn.model),
                        \(LedgerColumn.inputTokens),
                        \(LedgerColumn.cacheCreationTokens),
                        \(LedgerColumn.cacheReadTokens),
                        \(LedgerColumn.outputTokens),
                        \(LedgerColumn.requests)
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(\(LedgerColumn.bucketStart), \(LedgerColumn.modelKey)) DO UPDATE SET
                        \(LedgerColumn.model) = excluded.\(LedgerColumn.model),
                        \(LedgerColumn.inputTokens) =
                            \(LedgerColumn.inputTokens) + excluded.\(LedgerColumn.inputTokens),
                        \(LedgerColumn.cacheCreationTokens) =
                            \(LedgerColumn.cacheCreationTokens) + excluded.\(LedgerColumn.cacheCreationTokens),
                        \(LedgerColumn.cacheReadTokens) =
                            \(LedgerColumn.cacheReadTokens) + excluded.\(LedgerColumn.cacheReadTokens),
                        \(LedgerColumn.outputTokens) =
                            \(LedgerColumn.outputTokens) + excluded.\(LedgerColumn.outputTokens),
                        \(LedgerColumn.requests) =
                            \(LedgerColumn.requests) + excluded.\(LedgerColumn.requests)
                    """,
                arguments: [
                    row.bucketStart,
                    row.modelKey,
                    row.model,
                    row.inputTokens,
                    row.cacheCreationTokens,
                    row.cacheReadTokens,
                    row.outputTokens,
                    row.requests,
                ]
            )
        }
    }

    /// Rows whose day starts on or after `since`. Nil means all time.
    func fetchLocalTokenUsage(since: Date?) throws -> [LocalTokenUsage] {
        try dbQueue.read { db in
            var request = LocalTokenUsageRecord.all()
            if let since {
                request = request.filter(Column(LedgerColumn.bucketStart) >= since)
            }

            return try request
                .order(
                    Column(LedgerColumn.bucketStart).asc,
                    Column(LedgerColumn.modelKey).asc
                )
                .fetchAll(db)
                .map(\.usage)
        }
    }

    func fetchLocalScanWatermark(sourceKey: String) throws -> LocalScanWatermark? {
        try dbQueue.read { db in
            try LocalScanWatermarkRecord
                .filter(Column(LedgerColumn.sourceKey) == sourceKey)
                .fetchOne(db)?
                .watermark
        }
    }

    func saveLocalScanWatermark(_ watermark: LocalScanWatermark) throws {
        try dbQueue.write { db in
            try Self.saveLocalScanWatermark(watermark, in: db)
        }
    }

    private static func saveLocalScanWatermark(
        _ watermark: LocalScanWatermark,
        in db: Database
    ) throws {
        let record = LocalScanWatermarkRecord(watermark)

        try db.execute(
            sql: """
                INSERT INTO \(LedgerTable.localScanWatermarks) (
                    \(LedgerColumn.sourceKey),
                    \(LedgerColumn.fileSize),
                    \(LedgerColumn.fileMTime),
                    \(LedgerColumn.byteOffset),
                    \(LedgerColumn.updatedAt)
                )
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(\(LedgerColumn.sourceKey)) DO UPDATE SET
                    \(LedgerColumn.fileSize) = excluded.\(LedgerColumn.fileSize),
                    \(LedgerColumn.fileMTime) = excluded.\(LedgerColumn.fileMTime),
                    \(LedgerColumn.byteOffset) = excluded.\(LedgerColumn.byteOffset),
                    \(LedgerColumn.updatedAt) = excluded.\(LedgerColumn.updatedAt)
                """,
            arguments: [
                record.sourceKey,
                record.fileSize,
                record.fileMTime,
                record.byteOffset,
                record.updatedAt,
            ]
        )
    }

    /// Upsert on the session id: a session that parks, wakes and parks again is
    /// one card, not three.
    func saveParkedAgent(_ session: ParkedAgentSession) throws {
        try dbQueue.write { db in
            try ParkedAgentRecord(session).save(db)
        }
    }

    func fetchParkedAgents() throws -> [ParkedAgentSession] {
        try dbQueue.read { db in
            try ParkedAgentRecord
                .order(Column(LedgerColumn.parkedAt).desc)
                .fetchAll(db)
                .map(\.session)
        }
    }

    /// This is what dismissing a session means. There is no tombstone: if it
    /// writes again it comes back through the ordinary entry rule, which is what
    /// stops a dismissal from hiding something that is still running.
    func deleteParkedAgent(sessionID: String) throws {
        try dbQueue.write { db in
            _ = try ParkedAgentRecord
                .filter(Column(LedgerColumn.sessionID) == sessionID)
                .deleteAll(db)
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

    /// Appends an observation, but only when it differs from the newest one for
    /// the same account and kind. A window moves stepwise, so dropping repeats
    /// keeps the *value* series exact and takes the yearly volume from ~500k rows
    /// to ~15k.
    ///
    /// It is not lossless in every respect, and the difference matters. A repeat
    /// is dropped along with its `observedAt`, so the stored `observedAt` keeps
    /// meaning "when this value was **first** seen" and does not advance when a
    /// later fetch confirms the same value. Freshness must therefore be judged
    /// from the caller's record of its last successful fetch, never from this
    /// column — measuring it here made a stable reading age into "unknown"
    /// while the provider was still confirming it every few minutes.
    ///
    /// Implausible observations are discarded rather than stored.
    ///
    /// - Returns: whether the observation was believable. `true` covers both "a
    ///   row was inserted" and "an identical row already stood": in each case the
    ///   value is confirmed as of `window.observedAt`, which is what a caller
    ///   tracking freshness needs. `false` means the reading was rejected and
    ///   nothing about it may be believed.
    @discardableResult
    func saveRateWindow(_ window: RateWindow, accountID: UUID) throws -> Bool {
        guard window.isPlausible(now: window.observedAt) else { return false }

        try dbQueue.write { db in
            let newest = try RateWindowSampleRecord
                .filter(Column(LedgerColumn.accountID) == accountID.uuidString)
                .filter(Column(LedgerColumn.kind) == window.kind.rawValue)
                .order(Column(LedgerColumn.observedAt).desc)
                .fetchOne(db)

            if let newest,
               newest.usedFraction == window.usedFraction,
               Self.isSameStoredReset(newest.resetAt, window.resetAt) {
                return
            }

            try RateWindowSampleRecord(window, accountID: accountID).insert(db)
        }

        return true
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

    func deletionSummary(accountID: UUID) throws -> AccountDeletionSummary {
        try dbQueue.read { db in
            let key = accountID.uuidString
            let samples = RateWindowSampleRecord
                .filter(Column(LedgerColumn.accountID) == key)
            return AccountDeletionSummary(
                rateWindowSampleCount: try samples.fetchCount(db),
                earliestRateWindowObservedAt: try samples
                    .order(Column(LedgerColumn.observedAt).asc)
                    .fetchOne(db)?.observedAt,
                costSnapshotCount: try CostSnapshotRecord
                    .filter(Column(LedgerColumn.accountID) == key)
                    .fetchCount(db),
                usageSnapshotCount: try UsageSnapshotRecord
                    .filter(Column(LedgerColumn.accountID) == key)
                    .fetchCount(db)
            )
        }
    }

    /// Removes every row the account owns, in one transaction.
    ///
    /// The schema declares no foreign keys, so nothing cascades — each table has
    /// to be named explicitly. A table left out here keeps rows that no query
    /// will ever surface again. The single transaction is what keeps a failure
    /// part-way through from leaving a half-deleted account behind.
    func deleteAccount(id accountID: UUID) throws {
        try dbQueue.write { db in
            let key = accountID.uuidString
            for table in [
                LedgerTable.usageSnapshots,
                LedgerTable.costSnapshots,
                LedgerTable.estimateSnapshots,
                LedgerTable.syncRuns,
                LedgerTable.accountSyncStates,
                LedgerTable.syncWatermarks,
                LedgerTable.rateWindowSamples
            ] {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE \(LedgerColumn.accountID) = ?",
                    arguments: [key]
                )
            }
            try db.execute(
                sql: "DELETE FROM \(LedgerTable.accounts) WHERE \(LedgerColumn.id) = ?",
                arguments: [key]
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
