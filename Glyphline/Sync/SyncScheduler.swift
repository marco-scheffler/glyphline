import Foundation

final class SyncScheduler {
    private let ledger: LedgerStore
    private let credentials: CredentialStore

    init(ledger: LedgerStore, credentials: CredentialStore) {
        self.ledger = ledger
        self.credentials = credentials
    }

    func sync(account: Account, adapter: ProviderAdapter) async throws {
        guard let secret = try credentials.readSecret(for: account.credentialReference) else {
            throw SyncSchedulerError.missingCredential(accountID: account.id)
        }

        let result = try await adapter.sync(account: account, secret: secret)
        try ledger.upsertUsageSnapshots(result.usageSnapshots)
        try ledger.upsertCostSnapshots(result.costSnapshots)
        try ledger.upsertEstimateSnapshots(result.estimateSnapshots)
    }
}

enum SyncSchedulerError: Error, Equatable {
    case missingCredential(accountID: UUID)
}
