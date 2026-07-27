import Foundation

final class SyncScheduler {
    private let ledger: LedgerStore
    private let credentials: any CredentialStore

    init(ledger: LedgerStore, credentials: any CredentialStore) {
        self.ledger = ledger
        self.credentials = credentials
    }

    func sync(account: Account, adapter: any ProviderAdapter) async throws {
        guard adapter.providerID == account.providerID else {
            throw SyncSchedulerError.providerMismatch(
                accountProviderID: account.providerID,
                adapterProviderID: adapter.providerID
            )
        }

        let secret: String
        if adapter.requiresSecret {
            guard let stored = try credentials.readSecret(for: account.credentialReference) else {
                throw SyncSchedulerError.missingCredential(accountID: account.id)
            }
            secret = stored
        } else {
            secret = ""
        }

        let syncRunID = try ledger.startSyncRun(
            accountID: account.id,
            providerID: account.providerID,
            startedAt: Date()
        )

        let result: ProviderSyncResult
        do {
            result = try await adapter.sync(account: account, secret: secret)
        } catch {
            try recordFailedSyncRun(
                id: syncRunID,
                failureCode: .providerSyncFailed,
                underlyingError: error
            )
            throw error
        }

        do {
            try ledger.applySuccessfulSyncResult(
                result,
                syncRunID: syncRunID,
                finishedAt: result.syncedAt
            )
        } catch {
            try recordFailedSyncRun(
                id: syncRunID,
                failureCode: .ledgerWriteFailed,
                underlyingError: error
            )
            throw error
        }
    }

    private func recordFailedSyncRun(
        id: UUID,
        failureCode: SyncRunFailureCode,
        underlyingError: any Error
    ) throws {
        do {
            try ledger.finishSyncRun(
                id: id,
                status: .failed,
                message: failureCode.rawValue,
                finishedAt: Date()
            )
        } catch {
            throw SyncRunFailurePersistenceError(
                failureCode: failureCode.rawValue,
                underlyingError: underlyingError,
                metadataWriteError: error
            )
        }
    }
}

enum SyncSchedulerError: Error, Equatable {
    case missingCredential(accountID: UUID)
    case providerMismatch(accountProviderID: ProviderID, adapterProviderID: ProviderID)
}

private enum SyncRunFailureCode: String {
    case providerSyncFailed
    case ledgerWriteFailed
}

struct SyncRunFailurePersistenceError: Error {
    let failureCode: String
    let underlyingError: any Error
    let metadataWriteError: any Error

    init(failureCode: String, underlyingError: any Error, metadataWriteError: any Error) {
        self.failureCode = failureCode
        self.underlyingError = underlyingError
        self.metadataWriteError = metadataWriteError
    }
}

extension SyncRunFailurePersistenceError: LocalizedError {
    var errorDescription: String? {
        "Sync failed with code \(failureCode), and the failure metadata could not be persisted."
    }
}
