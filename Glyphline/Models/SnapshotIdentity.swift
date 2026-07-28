import Foundation

/// Derives a stable UUID for a snapshot so re-syncing a bucket updates it in place.
enum SnapshotIdentity {
    static func make(
        accountID: UUID,
        providerID: ProviderID,
        bucketStart: Date,
        bucketEnd: Date,
        discriminator: String
    ) -> UUID {
        let key = [
            accountID.uuidString,
            providerID.rawValue,
            String(bucketStart.timeIntervalSince1970),
            String(bucketEnd.timeIntervalSince1970),
            discriminator,
        ].joined(separator: "|")

        let bytes = makeUUIDBytes(from: key)
        let uuidString = bytes.enumerated().map { index, byte in
            let fragment = String(format: "%02x", byte)
            switch index {
            case 4, 6, 8, 10:
                return "-\(fragment)"
            default:
                return fragment
            }
        }.joined()

        return UUID(uuidString: uuidString) ?? UUID()
    }

    private static func makeUUIDBytes(from key: String) -> [UInt8] {
        var upper = UInt64(0xcbf29ce484222325)
        var lower = UInt64(0x84222325cbf29ce4)

        for byte in key.utf8 {
            upper = (upper ^ UInt64(byte)) &* 0x100000001b3
            lower = (lower ^ UInt64(byte)) &* 0x100000001b3 &+ 0x5c
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0 ..< 8 {
            bytes[index] = UInt8(truncatingIfNeeded: upper >> ((7 - index) * 8))
            bytes[index + 8] = UInt8(truncatingIfNeeded: lower >> ((7 - index) * 8))
        }

        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes
    }
}
