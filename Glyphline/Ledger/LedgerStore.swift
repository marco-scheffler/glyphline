import Foundation
import GRDB

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
                        \(LedgerColumn.claudeOrganizationID),
                        \(LedgerColumn.customName)
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(\(LedgerColumn.id)) DO UPDATE SET
                        \(LedgerColumn.providerID) = excluded.\(LedgerColumn.providerID),
                        \(LedgerColumn.displayName) = excluded.\(LedgerColumn.displayName),
                        \(LedgerColumn.credentialReference) = excluded.\(LedgerColumn.credentialReference),
                        \(LedgerColumn.createdAt) = excluded.\(LedgerColumn.createdAt),
                        \(LedgerColumn.isEnabled) = excluded.\(LedgerColumn.isEnabled),
                        \(LedgerColumn.quotaCredentialReference) = excluded.\(LedgerColumn.quotaCredentialReference),
                        \(LedgerColumn.claudeOrganizationID) = excluded.\(LedgerColumn.claudeOrganizationID),
                        \(LedgerColumn.customName) = excluded.\(LedgerColumn.customName)
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
                    record.customName,
                ]
            )
        }
    }

    /// Gives one account a user-chosen name, or — with nil or whitespace — takes
    /// it back and leaves the account on its derived name.
    ///
    /// An `UPDATE` of the single column rather than a read-modify-`saveAccount`:
    /// the caller holds a copy of the account that may be a sync tick out of
    /// date, and writing all of it back would carry that staleness into every
    /// other column just to change the name.
    func renameAccount(accountID: UUID, to name: String?) throws {
        let normalized = Account.normalizedName(name)

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE \(LedgerTable.accounts)
                    SET \(LedgerColumn.customName) = ?
                    WHERE \(LedgerColumn.id) = ?
                    """,
                arguments: [normalized, accountID.uuidString]
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

    /// Persists one scan: the daily deltas, the per-session deltas, and the
    /// watermarks that consume both.
    ///
    /// Takes the whole result rather than its parts. All three come from one
    /// pass and are meaningless apart: if the tokens land and the watermarks do
    /// not, the next scan reads those bytes again and double-counts them; if the
    /// watermarks land and the tokens do not, those bytes are never read again
    /// and the totals understate for good. One transaction: all of it, or none.
    func applyLocalScan(_ result: LocalScanResult, now: Date = Date()) throws {
        guard !result.usage.isEmpty || !result.sessionUsage.isEmpty
            || !result.watermarks.isEmpty || !result.seenMessages.isEmpty
        else { return }

        try dbQueue.write { db in
            try Self.addLocalTokenUsage(result.usage, in: db)
            try Self.addLocalSessionTokens(result.sessionUsage, in: db)
            // In the same transaction as the tokens, for the same reason the
            // watermarks are: an id stored without its tokens suppresses a real
            // record on the next fork and under-counts permanently, and tokens
            // stored without their id are counted again by the next copy.
            try Self.recordSeenMessages(result.seenMessages, in: db)
            for watermark in result.watermarks {
                try Self.saveLocalScanWatermark(watermark, in: db)
            }
            // Once per scan rather than once per insert: a delete by age over an
            // indexed column costs nothing next to the scan that preceded it,
            // and a table that only grows while new messages arrive is a table
            // that stops growing when they stop.
            try Self.pruneSeenMessages(before: now - LocalSeenMessageRetention.window, in: db)
        }
    }

    private static func recordSeenMessages(_ rows: [LocalSeenMessage], in db: Database) throws {
        for row in rows {
            // Conflicts should not happen — the scan skips an id it has already
            // seen — but if one does, the first sighting keeps its instant.
            // Refreshing it would let a message that keeps being re-copied sit
            // in the table forever, which is exactly what the window prevents.
            try db.execute(
                sql: """
                    INSERT INTO \(LedgerTable.localSeenMessages) (
                        \(LedgerColumn.messageID),
                        \(LedgerColumn.seenAt)
                    )
                    VALUES (?, ?)
                    ON CONFLICT(\(LedgerColumn.messageID)) DO NOTHING
                    """,
                arguments: [row.messageID, row.seenAt]
            )
        }
    }

    private static func pruneSeenMessages(before cutoff: Date, in db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM \(LedgerTable.localSeenMessages)
                WHERE \(LedgerColumn.seenAt) < ?
                """,
            arguments: [cutoff]
        )
    }

    /// Drops remembered message ids older than the retention window.
    ///
    /// Exposed for its own sake so the window is testable; production prunes
    /// through `applyLocalScan`, once per scan.
    func pruneSeenMessages(now: Date = Date()) throws {
        try dbQueue.write { db in
            try Self.pruneSeenMessages(before: now - LocalSeenMessageRetention.window, in: db)
        }
    }

    /// Every message id the scan has already counted and not yet pruned.
    ///
    /// Read whole, once per scan: the alternative is a query per transcript
    /// line, and a cold start reads millions of them.
    func fetchSeenMessageIDs() throws -> Set<String> {
        try dbQueue.read { db in
            try String.fetchSet(
                db,
                sql: "SELECT \(LedgerColumn.messageID) FROM \(LedgerTable.localSeenMessages)"
            )
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

    private static func addLocalSessionTokens(
        _ rows: [LocalSessionTokenUsage], in db: Database
    ) throws {
        for row in rows {
            try db.execute(
                sql: """
                    INSERT INTO \(LedgerTable.localSessionTokens) (
                        \(LedgerColumn.sessionID),
                        \(LedgerColumn.modelKey),
                        \(LedgerColumn.model),
                        \(LedgerColumn.inputTokens),
                        \(LedgerColumn.cacheCreationTokens),
                        \(LedgerColumn.cacheReadTokens),
                        \(LedgerColumn.outputTokens)
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(\(LedgerColumn.sessionID), \(LedgerColumn.modelKey)) DO UPDATE SET
                        \(LedgerColumn.model) = excluded.\(LedgerColumn.model),
                        \(LedgerColumn.inputTokens) =
                            \(LedgerColumn.inputTokens) + excluded.\(LedgerColumn.inputTokens),
                        \(LedgerColumn.cacheCreationTokens) =
                            \(LedgerColumn.cacheCreationTokens) + excluded.\(LedgerColumn.cacheCreationTokens),
                        \(LedgerColumn.cacheReadTokens) =
                            \(LedgerColumn.cacheReadTokens) + excluded.\(LedgerColumn.cacheReadTokens),
                        \(LedgerColumn.outputTokens) =
                            \(LedgerColumn.outputTokens) + excluded.\(LedgerColumn.outputTokens)
                    """,
                arguments: [
                    row.sessionID,
                    row.modelKey,
                    row.model,
                    row.inputTokens,
                    row.cacheCreationTokens,
                    row.cacheReadTokens,
                    row.outputTokens,
                ]
            )
        }
    }

    /// Total tokens per session, summed across models. Sessions with no rows are
    /// absent rather than zero — a session nobody has scanned has no total, and
    /// zero would be a confidently wrong number.
    func fetchSessionTokens(sessionIDs: [String]) throws -> [String: Int64] {
        guard !sessionIDs.isEmpty else { return [:] }

        return try dbQueue.read { db in
            try LocalSessionTokenRecord
                .filter(sessionIDs.contains(Column(LedgerColumn.sessionID)))
                .fetchAll(db)
                .reduce(into: [String: Int64]()) { totals, record in
                    totals[record.sessionID, default: 0] += record.usage.totalTokens
                }
        }
    }

    /// Work tokens per session, summed across models. Absent rather than zero for
    /// a session with no rows, for the same reason `fetchSessionTokens` is: a
    /// session nobody has scanned has no total, and zero would be a confidently
    /// wrong number.
    func fetchSessionWorkTokens(sessionIDs: [String]) throws -> [String: Int64] {
        guard !sessionIDs.isEmpty else { return [:] }

        return try dbQueue.read { db in
            try LocalSessionTokenRecord
                .filter(sessionIDs.contains(Column(LedgerColumn.sessionID)))
                .fetchAll(db)
                .reduce(into: [String: Int64]()) { totals, record in
                    totals[record.sessionID, default: 0] += record.usage.workTokens
                }
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
