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
}
