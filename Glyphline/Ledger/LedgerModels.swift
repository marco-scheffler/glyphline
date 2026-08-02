import Foundation

enum LedgerStoreError: Error, Equatable {
    /// A write referenced an account that is not in the ledger.
    case unknownAccount
}

/// Internal rather than file-private because both sides of the model/record
/// divide need the same key: the domain types expose it as `modelKey`, and
/// `UsageSnapshotRecord` writes it into the column the snapshot tables key on.
/// A second copy would be a second chance for the two to disagree.
enum LedgerModelIdentity {
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

/// One session's token total for one model, read from the local Claude Code
/// transcripts.
///
/// The daily totals answer "what did this machine spend"; this answers "what did
/// this session spend", which is what a lap counts.
///
/// The model is kept rather than summed away so the figure stays priceable
/// through `PricingCatalog` — the alternative buys a smaller table and gives up
/// cost per session, which is close to the reason this app exists.
///
/// A write is a *delta*, exactly as `LocalTokenUsage` is: the reader emits only
/// the tokens read since the last watermark, and the store adds them to what is
/// already there.
struct LocalSessionTokenUsage: Equatable, Sendable {
    /// The Claude Code `sessionId`. A subagent transcript carries its parent's,
    /// so a session's total already includes everything it dispatched.
    var sessionID: String
    var model: String?
    var inputTokens: Int64 = 0
    var cacheCreationTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var outputTokens: Int64 = 0

    var modelKey: String { LedgerModelIdentity.makeKey(for: model) }

    var totalTokens: Int64 {
        inputTokens + cacheCreationTokens + cacheReadTokens + outputTokens
    }

    /// What the session produced, as opposed to what it cost to keep going.
    ///
    /// Cache reads are excluded: each turn re-reads the entire context, so they
    /// accumulate with the length of the conversation rather than with the work
    /// in it. Across 309 sessions on the reference machine they made up about
    /// nine tenths of every figure, and a lap counted in them would measure
    /// mostly how long a session had been open.
    var workTokens: Int64 {
        inputTokens + cacheCreationTokens + outputTokens
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
    /// What the session was doing when it parked, as its transcript reported it.
    /// Stored because two parked sessions from one checkout are otherwise the
    /// same word twice.
    var aiTitle: String? = nil
    var slug: String? = nil

    var id: String { sessionID }

    /// The same fallback chain a running session uses — see `SessionLabel`.
    var displayTitle: String {
        SessionLabel.displayTitle(aiTitle: aiTitle, slug: slug, cwd: cwd)
    }

    var repositoryName: String { SessionLabel.repositoryName(cwd: cwd) }
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
