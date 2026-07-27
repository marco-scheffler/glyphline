import Foundation

struct FixtureProviderAdapter: ProviderAdapter {
    let providerID: ProviderID

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        _ = secret

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(86_400)

        return ProviderSyncResult(
            providerID: providerID,
            accountID: account.id,
            capabilities: ProviderCapabilities(
                supportsUsage: true,
                supportsActualCost: false,
                supportsResetDate: true,
                supportsModelBreakdown: true,
                dataQuality: .exact,
                message: nil
            ),
            billingPeriod: BillingPeriod(
                startsAt: start,
                endsAt: nil,
                resetAt: end.addingTimeInterval(30 * 86_400)
            ),
            usageSnapshots: [
                UsageSnapshot(
                    id: makeSnapshotID(
                        accountID: account.id,
                        providerID: providerID,
                        bucketStart: start,
                        bucketEnd: end,
                        kind: "usage"
                    ),
                    accountID: account.id,
                    providerID: providerID,
                    bucketStart: start,
                    bucketEnd: end,
                    model: "fixture-model",
                    inputTokens: 1_000,
                    outputTokens: 500,
                    requests: 12,
                    quality: .exact
                )
            ],
            costSnapshots: [],
            estimateSnapshots: [
                EstimateSnapshot(
                    id: makeSnapshotID(
                        accountID: account.id,
                        providerID: providerID,
                        bucketStart: start,
                        bucketEnd: end,
                        kind: "estimate"
                    ),
                    accountID: account.id,
                    providerID: providerID,
                    bucketStart: start,
                    bucketEnd: end,
                    estimatedAmountMicros: 2_500,
                    currency: "USD",
                    quality: .estimated
                )
            ],
            syncedAt: start.addingTimeInterval(12)
        )
    }

    private func makeSnapshotID(
        accountID: UUID,
        providerID: ProviderID,
        bucketStart: Date,
        bucketEnd: Date,
        kind: String
    ) -> UUID {
        let key = [
            accountID.uuidString,
            providerID.rawValue,
            kind,
            String(bucketStart.timeIntervalSince1970),
            String(bucketEnd.timeIntervalSince1970)
        ].joined(separator: "|")

        let bytes = Self.makeUUIDBytes(from: key)
        let uuidString = bytes.enumerated().map { index, byte in
            let chunk = String(format: "%02x", byte)
            switch index {
            case 4, 6, 8, 10:
                return "-\(chunk)"
            default:
                return chunk
            }
        }.joined()

        return UUID(uuidString: uuidString)!
    }

    private static func makeUUIDBytes(from key: String) -> [UInt8] {
        var first = UInt64(0xcbf29ce484222325)
        var second = UInt64(0x84222325cbf29ce4)

        for byte in key.utf8 {
            first = fnvStep(first, byte: byte)
            second = fnvStep(second, byte: byte ^ 0x5c)
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: first >> ((7 - index) * 8))
            bytes[index + 8] = UInt8(truncatingIfNeeded: second >> ((7 - index) * 8))
        }

        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes
    }

    private static func fnvStep(_ current: UInt64, byte: UInt8) -> UInt64 {
        (current ^ UInt64(byte)) &* 0x100000001b3
    }
}
