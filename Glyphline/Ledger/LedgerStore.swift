import Foundation
import GRDB

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

struct DailyUsageSummary: Identifiable, Equatable, Sendable {
    let accountID: UUID
    let dayStart: Date
    var inputTokens: Int64
    var outputTokens: Int64
    var requests: Int64
    var estimatedAmountMicros: Int64?
    var currency: String?
    var quality: DataQuality

    var id: String { "\(accountID.uuidString)-\(dayStart.timeIntervalSinceReferenceDate)" }
    var totalTokens: Int64 { inputTokens + outputTokens }
}

private struct DailyUsageAccumulator {
    let accountID: UUID
    let dayStart: Date
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var requests: Int64 = 0
    var estimatedAmountMicros: Int64?
    var currency: String?
    var quality: DataQuality?

    mutating func add(_ snapshot: UsageSnapshot) {
        inputTokens += snapshot.inputTokens
        outputTokens += snapshot.outputTokens
        requests += snapshot.requests
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
    var outputTokens: Int64
    var requests: Int64
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
        guard !snapshots.isEmpty else {
            return
        }

        try dbQueue.write { db in
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
                            \(LedgerColumn.outputTokens),
                            \(LedgerColumn.requests),
                            \(LedgerColumn.quality)
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        record.outputTokens,
                        record.requests,
                        record.quality,
                    ]
                )
            }
        }
    }

    func upsertCostSnapshots(_ snapshots: [CostSnapshot]) throws {
        guard !snapshots.isEmpty else {
            return
        }

        try dbQueue.write { db in
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
    }

    func upsertEstimateSnapshots(_ snapshots: [EstimateSnapshot]) throws {
        guard !snapshots.isEmpty else {
            return
        }

        try dbQueue.write { db in
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

    func finishSyncRun(id: UUID, status: SyncRun.Status, message: String?, finishedAt: Date) throws {
        try dbQueue.write { db in
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
 .order(Column(LedgerColumn.bucketStart), Column(LedgerColumn.bucketEnd))
 .fetchAll(db)
 .map(\.snapshot)
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
 var accumulator = summariesByDay[dayStart] ?? DailyUsageAccumulator(accountID: accountID, dayStart: dayStart)
 accumulator.add(snapshot)
 summariesByDay[dayStart] = accumulator
 }

 for snapshot in estimateSnapshots {
 let dayStart = DailySummaryCalendar.utc.startOfDay(for: snapshot.bucketStart)
 var accumulator = summariesByDay[dayStart] ?? DailyUsageAccumulator(accountID: accountID, dayStart: dayStart)
 accumulator.add(snapshot)
 summariesByDay[dayStart] = accumulator
 }

 return summariesByDay.values
 .map { $0.summary() }
 .sorted { lhs, rhs in
 lhs.dayStart > rhs.dayStart
 }
 }
 }

 func fetchSyncRuns(accountID: UUID) throws -> [SyncRun] {
 try dbQueue.read { db in
 try SyncRunRecord
                .filter(Column(LedgerColumn.accountID) == accountID.uuidString)
                .order(Column(LedgerColumn.startedAt).desc, Column(LedgerColumn.id).desc)
                .fetchAll(db)
                .map(\.syncRun)
        }
    }
}
