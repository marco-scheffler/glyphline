import Foundation
import GRDB

// The GRDB row shapes behind `LedgerStore`. Each one mirrors a table in
// `LedgerTable`, and carries the conversion to and from the domain type the
// Dashboard actually reads — nothing here is meant to leave the ledger.
//
// They were file-private while they shared a file with `LedgerStore`. Moving
// them out costs exactly that: the twelve type declarations are now internal,
// because the store's queries name them. Their members were already internal
// and are unchanged.

struct AccountRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.accounts

    var id: String
    var providerID: String
    var displayName: String
    var customName: String?
    var credentialReference: String
    var createdAt: Date
    var isEnabled: Bool
    var quotaCredentialReference: String?
    var claudeOrganizationID: String?

    init(_ account: Account) {
        id = account.id.uuidString
        providerID = account.providerID.rawValue
        displayName = account.displayName
        customName = account.customName
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
            claudeOrganizationID: claudeOrganizationID,
            customName: customName
        )
    }
}

struct UsageSnapshotRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
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

struct CostSnapshotRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
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

struct EstimateSnapshotRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
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

struct SyncRunRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
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

struct AccountSyncStateRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
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

struct SyncWatermarkRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
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

struct LocalTokenUsageRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
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

struct LocalSessionTokenRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.localSessionTokens

    var sessionID: String
    var modelKey: String
    var model: String?
    var inputTokens: Int64
    var cacheCreationTokens: Int64
    var cacheReadTokens: Int64
    var outputTokens: Int64

    var usage: LocalSessionTokenUsage {
        LocalSessionTokenUsage(
            sessionID: sessionID,
            model: model,
            inputTokens: inputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens
        )
    }
}

struct LocalScanWatermarkRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
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

struct ParkedAgentRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = LedgerTable.agentverseParked

    var sessionID: String
    var cwd: String
    var gitBranch: String?
    var subagentCount: Int
    var lastActivityAt: Date
    var parkedAt: Date
    var aiTitle: String?
    var slug: String?

    init(_ session: ParkedAgentSession) {
        sessionID = session.sessionID
        cwd = session.cwd
        gitBranch = session.gitBranch
        subagentCount = session.subagentCount
        lastActivityAt = session.lastActivityAt
        parkedAt = session.parkedAt
        aiTitle = session.aiTitle
        slug = session.slug
    }

    var session: ParkedAgentSession {
        ParkedAgentSession(
            sessionID: sessionID,
            cwd: cwd,
            gitBranch: gitBranch,
            subagentCount: subagentCount,
            lastActivityAt: lastActivityAt,
            parkedAt: parkedAt,
            aiTitle: aiTitle,
            slug: slug
        )
    }
}

struct RateWindowSampleRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
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
