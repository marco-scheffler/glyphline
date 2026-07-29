import Foundation

/// Decodes claude.ai's usage response.
///
/// Only `five_hour` and `seven_day` are part of the contract. The response also
/// carries internal codename fields (`tangelo`, `nimbus_quill`, …) that are
/// always null and may vanish, and billing fields (`spend`, `extra_usage`) that
/// belong to the cost ledger rather than here. Both are deliberately unread.
struct ClaudeUsageResponse: Decodable, Equatable, Sendable {
    struct Window: Decodable, Equatable, Sendable {
        /// A percentage, 0…100 — not a fraction.
        var utilization: Double
        var resetsAt: Date

        private enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    var fiveHour: Window?
    var sevenDay: Window?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    static func decode(_ data: Data) throws -> ClaudeUsageResponse {
        let decoder = JSONDecoder()
        // Timestamps carry microseconds and an offset; .iso8601 rejects
        // fractional seconds, so the fractional variant is required.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: text) { return date }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            guard let date = plain.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "unrecognised timestamp"
                )
            }
            return date
        }
        return try decoder.decode(ClaudeUsageResponse.self, from: data)
    }

    /// Maps to the app's window model.
    ///
    /// The division by 100 is the only arithmetic here, and it fails safe: a
    /// forgotten division puts the value outside 0…1, `isPlausible` discards it,
    /// nothing is written, and the account stays grey. The bug surfaces as
    /// missing data rather than as "400 % used".
    func rateWindows(observedAt: Date) -> [RateWindow] {
        var windows: [RateWindow] = []

        if let fiveHour {
            windows.append(
                RateWindow(
                    kind: .rollingFiveHours,
                    usedFraction: fiveHour.utilization / 100,
                    resetAt: fiveHour.resetsAt,
                    observedAt: observedAt
                )
            )
        }

        if let sevenDay {
            windows.append(
                RateWindow(
                    kind: .weekly,
                    usedFraction: sevenDay.utilization / 100,
                    resetAt: sevenDay.resetsAt,
                    observedAt: observedAt
                )
            )
        }

        return windows
    }
}
