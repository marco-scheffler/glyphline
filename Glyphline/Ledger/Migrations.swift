import GRDB

enum LedgerTable {
    static let accounts = "accounts"
    static let usageSnapshots = "usageSnapshots"
    static let costSnapshots = "costSnapshots"
    static let estimateSnapshots = "estimateSnapshots"
    static let syncRuns = "syncRuns"
    static let accountSyncStates = "accountSyncStates"
    static let syncWatermarks = "syncWatermarks"
    static let rateWindowSamples = "rateWindowSamples"
    static let localTokenUsage = "localTokenUsage"
    static let localScanWatermarks = "localScanWatermarks"
    static let localSessionTokens = "localSessionTokens"
    static let agentverseParked = "agentverseParked"
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
    static let cacheCreationTokens = "cacheCreationTokens"
    static let cacheReadTokens = "cacheReadTokens"
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
    static let supportsUsage = "supportsUsage"
    static let supportsActualCost = "supportsActualCost"
    static let supportsResetDate = "supportsResetDate"
    static let supportsModelBreakdown = "supportsModelBreakdown"
    static let billingStartsAt = "billingStartsAt"
    static let billingEndsAt = "billingEndsAt"
    static let billingResetAt = "billingResetAt"
    static let updatedAt = "updatedAt"
    static let sourceKey = "sourceKey"
    static let fileSize = "fileSize"
    static let fileMTime = "fileMTime"
    static let byteOffset = "byteOffset"
    static let backfillCompletedThrough = "backfillCompletedThrough"
    static let kind = "kind"
    static let observedAt = "observedAt"
    static let usedFraction = "usedFraction"
    static let resetAt = "resetAt"
    static let quotaCredentialReference = "quotaCredentialReference"
    static let claudeOrganizationID = "claudeOrganizationID"
    static let sessionID = "sessionID"
    static let cwd = "cwd"
    static let gitBranch = "gitBranch"
    static let subagentCount = "subagentCount"
    static let lastActivityAt = "lastActivityAt"
    static let parkedAt = "parkedAt"
}

enum Migrations {
    static func migrate(_ dbQueue: DatabaseQueue) throws {
        try makeMigrator().migrate(dbQueue)
    }

    static func makeMigrator() -> DatabaseMigrator {
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

        migrator.registerMigration("v3_create_account_sync_states") { db in
            try db.create(table: LedgerTable.accountSyncStates) { table in
                table.column(LedgerColumn.accountID, .text).primaryKey()
                table.column(LedgerColumn.providerID, .text).notNull()
                table.column(LedgerColumn.supportsUsage, .boolean).notNull()
                table.column(LedgerColumn.supportsActualCost, .boolean).notNull()
                table.column(LedgerColumn.supportsResetDate, .boolean).notNull()
                table.column(LedgerColumn.supportsModelBreakdown, .boolean).notNull()
                table.column(LedgerColumn.quality, .text).notNull()
                table.column(LedgerColumn.message, .text)
                table.column(LedgerColumn.billingStartsAt, .datetime)
                table.column(LedgerColumn.billingEndsAt, .datetime)
                table.column(LedgerColumn.billingResetAt, .datetime)
                table.column(LedgerColumn.updatedAt, .datetime).notNull()
            }
        }

        migrator.registerMigration("v4_usage_token_classes") { db in
            let rebuilt = "usageSnapshots_v4"

            try db.create(table: rebuilt) { table in
                table.column(LedgerColumn.id, .text).primaryKey()
                table.column(LedgerColumn.accountID, .text).notNull().indexed()
                table.column(LedgerColumn.providerID, .text).notNull()
                table.column(LedgerColumn.bucketStart, .datetime).notNull()
                table.column(LedgerColumn.bucketEnd, .datetime).notNull()
                table.column(LedgerColumn.model, .text)
                table.column(LedgerColumn.modelKey, .text).notNull()
                table.column(LedgerColumn.inputTokens, .integer).notNull()
                table.column(LedgerColumn.cacheCreationTokens, .integer).notNull().defaults(to: 0)
                table.column(LedgerColumn.cacheReadTokens, .integer).notNull().defaults(to: 0)
                table.column(LedgerColumn.outputTokens, .integer).notNull()
                table.column(LedgerColumn.requests, .integer)
                table.column(LedgerColumn.quality, .text).notNull()
                table.uniqueKey([
                    LedgerColumn.accountID,
                    LedgerColumn.providerID,
                    LedgerColumn.bucketStart,
                    LedgerColumn.bucketEnd,
                    LedgerColumn.modelKey,
                ])
            }

            try db.execute(
                sql: """
                    INSERT INTO \(rebuilt) (
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
                    SELECT
                        \(LedgerColumn.id),
                        \(LedgerColumn.accountID),
                        \(LedgerColumn.providerID),
                        \(LedgerColumn.bucketStart),
                        \(LedgerColumn.bucketEnd),
                        \(LedgerColumn.model),
                        \(LedgerColumn.modelKey),
                        \(LedgerColumn.inputTokens),
                        0,
                        0,
                        \(LedgerColumn.outputTokens),
                        \(LedgerColumn.requests),
                        \(LedgerColumn.quality)
                    FROM \(LedgerTable.usageSnapshots)
                    """
            )

            try db.drop(table: LedgerTable.usageSnapshots)
            try db.rename(table: rebuilt, to: LedgerTable.usageSnapshots)
        }

        migrator.registerMigration("v5_sync_watermarks") { db in
            try db.create(table: LedgerTable.syncWatermarks) { table in
                table.column(LedgerColumn.sourceKey, .text).primaryKey()
                table.column(LedgerColumn.accountID, .text).notNull().indexed()
                table.column(LedgerColumn.fileSize, .integer).notNull()
                table.column(LedgerColumn.fileMTime, .datetime).notNull()
                table.column(LedgerColumn.byteOffset, .integer).notNull()
                table.column(LedgerColumn.updatedAt, .datetime).notNull()
            }

            try db.alter(table: LedgerTable.accountSyncStates) { table in
                table.add(column: LedgerColumn.backfillCompletedThrough, .datetime)
            }
        }

        migrator.registerMigration("v6_rate_window_samples") { db in
            // Append-only observation series. Deliberately no unique constraint on
            // (accountID, kind, observedAt) beyond the surrogate primary key: every
            // row is a distinct observation and must never replace another.
            try db.create(table: LedgerTable.rateWindowSamples) { table in
                table.column(LedgerColumn.id, .text).primaryKey()
                table.column(LedgerColumn.accountID, .text).notNull()
                table.column(LedgerColumn.kind, .text).notNull()
                table.column(LedgerColumn.observedAt, .datetime).notNull()
                table.column(LedgerColumn.usedFraction, .double)
                table.column(LedgerColumn.resetAt, .datetime).notNull()
            }

            // Every render reads "newest sample per account per kind"; SQLite scans
            // this index backwards for that, so ascending order is sufficient.
            try db.create(
                index: "index_rateWindowSamples_on_account_kind_observedAt",
                on: LedgerTable.rateWindowSamples,
                columns: [
                    LedgerColumn.accountID,
                    LedgerColumn.kind,
                    LedgerColumn.observedAt,
                ]
            )

            try db.alter(table: LedgerTable.accounts) { table in
                table.add(column: LedgerColumn.quotaCredentialReference, .text)
            }
        }

        migrator.registerMigration("v7_claude_organization_id") { db in
            try db.alter(table: LedgerTable.accounts) { table in
                table.add(column: LedgerColumn.claudeOrganizationID, .text)
            }
        }

        migrator.registerMigration("v8_rate_window_reset_optional") { db in
            // A window with no reset instant is a real state — a subscription
            // that has not been used yet has nothing to reset — and the NOT NULL
            // constraint made it unstorable. SQLite cannot drop a NOT NULL in
            // place, so the table is recreated and copied, exactly as v4 did.
            let rebuilt = "rateWindowSamples_v8"

            try db.create(table: rebuilt) { table in
                table.column(LedgerColumn.id, .text).primaryKey()
                table.column(LedgerColumn.accountID, .text).notNull()
                table.column(LedgerColumn.kind, .text).notNull()
                table.column(LedgerColumn.observedAt, .datetime).notNull()
                table.column(LedgerColumn.usedFraction, .double)
                // The one difference from v6: nullable.
                table.column(LedgerColumn.resetAt, .datetime)
            }

            // Every column copied straight across — this migration changes what
            // the column may hold, never what any existing row holds.
            try db.execute(
                sql: """
                    INSERT INTO \(rebuilt) (
                        \(LedgerColumn.id),
                        \(LedgerColumn.accountID),
                        \(LedgerColumn.kind),
                        \(LedgerColumn.observedAt),
                        \(LedgerColumn.usedFraction),
                        \(LedgerColumn.resetAt)
                    )
                    SELECT
                        \(LedgerColumn.id),
                        \(LedgerColumn.accountID),
                        \(LedgerColumn.kind),
                        \(LedgerColumn.observedAt),
                        \(LedgerColumn.usedFraction),
                        \(LedgerColumn.resetAt)
                    FROM \(LedgerTable.rateWindowSamples)
                    """
            )

            try db.drop(table: LedgerTable.rateWindowSamples)
            try db.rename(table: rebuilt, to: LedgerTable.rateWindowSamples)

            // Dropping the old table took its index with it, and the rename does
            // not bring one along. Recreated under the v6 name so the schema
            // ends up identical apart from the nullability — without this the
            // "newest sample per account per kind" read degrades to a scan.
            try db.create(
                index: "index_rateWindowSamples_on_account_kind_observedAt",
                on: LedgerTable.rateWindowSamples,
                columns: [
                    LedgerColumn.accountID,
                    LedgerColumn.kind,
                    LedgerColumn.observedAt,
                ]
            )
        }

        migrator.registerMigration("v9_local_token_usage") { db in
            // Machine-wide daily totals per model. There is deliberately no
            // account column: the transcripts under ~/.claude/projects carry no
            // marker of which subscription was active, and `/login` writes into
            // the same directory. These totals are the sum across every
            // subscription and cannot be split. A nullable column or a sentinel
            // id would be read as an account by the next person to look.
            try db.create(table: LedgerTable.localTokenUsage) { table in
                table.column(LedgerColumn.bucketStart, .datetime).notNull()
                table.column(LedgerColumn.modelKey, .text).notNull()
                table.column(LedgerColumn.model, .text)
                table.column(LedgerColumn.inputTokens, .integer).notNull().defaults(to: 0)
                table.column(LedgerColumn.cacheCreationTokens, .integer).notNull().defaults(to: 0)
                table.column(LedgerColumn.cacheReadTokens, .integer).notNull().defaults(to: 0)
                table.column(LedgerColumn.outputTokens, .integer).notNull().defaults(to: 0)
                table.column(LedgerColumn.requests, .integer).notNull().defaults(to: 0)
                table.primaryKey([LedgerColumn.bucketStart, LedgerColumn.modelKey])
            }

            // The same shape as syncWatermarks minus accountID, for the same
            // reason: a machine-wide scan has no account.
            try db.create(table: LedgerTable.localScanWatermarks) { table in
                table.column(LedgerColumn.sourceKey, .text).primaryKey()
                table.column(LedgerColumn.fileSize, .integer).notNull()
                table.column(LedgerColumn.fileMTime, .datetime).notNull()
                table.column(LedgerColumn.byteOffset, .integer).notNull()
                table.column(LedgerColumn.updatedAt, .datetime).notNull()
            }
        }

        migrator.registerMigration("v10_agentverse_parked") { db in
            // Sessions that dropped off the map but have not been thrown away yet.
            //
            // Persisted rather than held in memory, because the 96-hour expiry is
            // otherwise meaningless: every restart would clear the pit lane and the
            // deadline would never elapse. With the rows on disk, dismissing a session
            // is simply deleting one, and a session that starts writing again
            // re-enters through the ordinary 60-minute rule — no second mechanism,
            // and no way to stay blind to something that is running.
            //
            // Account-free like the rest of the local scan: a transcript carries no
            // marker of which subscription produced it.
            try db.create(table: LedgerTable.agentverseParked) { table in
                table.column(LedgerColumn.sessionID, .text).primaryKey()
                table.column(LedgerColumn.cwd, .text).notNull()
                table.column(LedgerColumn.gitBranch, .text)
                table.column(LedgerColumn.subagentCount, .integer).notNull().defaults(to: 0)
                table.column(LedgerColumn.lastActivityAt, .datetime).notNull()
                table.column(LedgerColumn.parkedAt, .datetime).notNull()
            }

            // The pit lane is read newest-first and never any other way. Expiry
            // needs no ordered query of its own: `AgentverseRules` decides it in
            // memory from this same fetch, so one index covers the only read
            // there is.
            try db.create(
                index: "index_agentverseParked_on_parkedAt",
                on: LedgerTable.agentverseParked,
                columns: [LedgerColumn.parkedAt]
            )
        }

        migrator.registerMigration("v11_local_session_tokens") { db in
            // What one session spent, per model. The daily table answers what the
            // machine spent; this answers what one session spent, which is the
            // figure a lap is counted in.
            //
            // The model is part of the key rather than summed away so the totals
            // stay priceable through the pricing catalog. It costs on the order of
            // a thousand rows today and twenty thousand after a year — nothing —
            // and adding it later would mean a migration and a full rescan.
            //
            // Account-free like the rest of the local scan: a transcript carries
            // no marker of which subscription produced it.
            try db.create(table: LedgerTable.localSessionTokens) { table in
                table.column(LedgerColumn.sessionID, .text).notNull()
                table.column(LedgerColumn.modelKey, .text).notNull()
                table.column(LedgerColumn.model, .text)
                table.column(LedgerColumn.inputTokens, .integer).notNull().defaults(to: 0)
                table.column(LedgerColumn.cacheCreationTokens, .integer).notNull().defaults(to: 0)
                table.column(LedgerColumn.cacheReadTokens, .integer).notNull().defaults(to: 0)
                table.column(LedgerColumn.outputTokens, .integer).notNull().defaults(to: 0)
                table.primaryKey([LedgerColumn.sessionID, LedgerColumn.modelKey])
            }
        }

        return migrator
    }
}
