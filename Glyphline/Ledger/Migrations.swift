import GRDB

enum LedgerTable {
    static let accounts = "accounts"
    static let usageSnapshots = "usageSnapshots"
    static let costSnapshots = "costSnapshots"
    static let estimateSnapshots = "estimateSnapshots"
    static let syncRuns = "syncRuns"
}

enum LedgerColumn {
    static let id = "id"
    static let accountID = "accountID"
    static let providerID = "providerID"
    static let displayName = "displayName"
    static let credentialReference = "credentialReference"
    static let createdAt = "createdAt"
    static let isEnabled = "isEnabled"
    static let bucketStart = "bucketStart"
    static let bucketEnd = "bucketEnd"
    static let model = "model"
    static let modelKey = "modelKey"
    static let inputTokens = "inputTokens"
    static let outputTokens = "outputTokens"
    static let requests = "requests"
    static let quality = "quality"
    static let amountMicros = "amountMicros"
    static let estimatedAmountMicros = "estimatedAmountMicros"
    static let currency = "currency"
    static let startedAt = "startedAt"
    static let finishedAt = "finishedAt"
    static let status = "status"
    static let message = "message"
}

enum Migrations {
    static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_ledger") { db in
            try db.create(table: LedgerTable.accounts) { table in
                table.column(LedgerColumn.id, .text).primaryKey()
                table.column(LedgerColumn.providerID, .text).notNull()
                table.column(LedgerColumn.displayName, .text).notNull()
                table.column(LedgerColumn.credentialReference, .text).notNull()
                table.column(LedgerColumn.createdAt, .datetime).notNull()
                table.column(LedgerColumn.isEnabled, .boolean).notNull()
            }

            try db.create(table: LedgerTable.usageSnapshots) { table in
                table.column(LedgerColumn.id, .text).primaryKey()
                table.column(LedgerColumn.accountID, .text).notNull().indexed()
                table.column(LedgerColumn.providerID, .text).notNull()
                table.column(LedgerColumn.bucketStart, .datetime).notNull()
                table.column(LedgerColumn.bucketEnd, .datetime).notNull()
                table.column(LedgerColumn.model, .text)
                table.column(LedgerColumn.modelKey, .text).notNull()
                table.column(LedgerColumn.inputTokens, .integer).notNull()
                table.column(LedgerColumn.outputTokens, .integer).notNull()
                table.column(LedgerColumn.requests, .integer).notNull()
                table.column(LedgerColumn.quality, .text).notNull()
                table.uniqueKey([
                    LedgerColumn.accountID,
                    LedgerColumn.providerID,
                    LedgerColumn.bucketStart,
                    LedgerColumn.bucketEnd,
                    LedgerColumn.modelKey,
                ])
            }

            try db.create(table: LedgerTable.costSnapshots) { table in
                table.column(LedgerColumn.id, .text).primaryKey()
                table.column(LedgerColumn.accountID, .text).notNull().indexed()
                table.column(LedgerColumn.providerID, .text).notNull()
                table.column(LedgerColumn.bucketStart, .datetime).notNull()
                table.column(LedgerColumn.bucketEnd, .datetime).notNull()
                table.column(LedgerColumn.amountMicros, .integer).notNull()
                table.column(LedgerColumn.currency, .text).notNull()
                table.column(LedgerColumn.quality, .text).notNull()
                table.uniqueKey([
                    LedgerColumn.accountID,
                    LedgerColumn.providerID,
                    LedgerColumn.bucketStart,
                    LedgerColumn.bucketEnd,
                    LedgerColumn.currency,
                ])
            }

            try db.create(table: LedgerTable.estimateSnapshots) { table in
                table.column(LedgerColumn.id, .text).primaryKey()
                table.column(LedgerColumn.accountID, .text).notNull().indexed()
                table.column(LedgerColumn.providerID, .text).notNull()
                table.column(LedgerColumn.bucketStart, .datetime).notNull()
                table.column(LedgerColumn.bucketEnd, .datetime).notNull()
                table.column(LedgerColumn.estimatedAmountMicros, .integer).notNull()
                table.column(LedgerColumn.currency, .text).notNull()
                table.column(LedgerColumn.quality, .text).notNull()
                table.uniqueKey([
                    LedgerColumn.accountID,
                    LedgerColumn.providerID,
                    LedgerColumn.bucketStart,
                    LedgerColumn.bucketEnd,
                    LedgerColumn.currency,
                ])
            }
        }

        migrator.registerMigration("v2_create_sync_runs") { db in
            try db.create(table: LedgerTable.syncRuns) { table in
                table.column(LedgerColumn.id, .text).primaryKey()
                table.column(LedgerColumn.accountID, .text).notNull().indexed()
                table.column(LedgerColumn.providerID, .text).notNull()
                table.column(LedgerColumn.startedAt, .datetime).notNull()
                table.column(LedgerColumn.finishedAt, .datetime)
                table.column(LedgerColumn.status, .text).notNull()
                table.column(LedgerColumn.message, .text)
            }
        }

        try migrator.migrate(dbQueue)
    }
}
