import Foundation

/// Decodes claude.ai's usage response.
///
/// Only `five_hour` and `seven_day` are part of the contract. The response also
/// carries internal codename fields (`tangelo`, `nimbus_quill`, …) that are
/// always null and may vanish, and billing fields (`spend`, `extra_usage`) that
/// belong to the cost ledger rather than here. Both are deliberately unread.
struct ClaudeUsageResponse: Decodable, Equatable, Sendable {
    /// Both fields are tolerated as absent, null or — for the date — malformed.
    /// A subscription with no active window reports no reset instant, and that
    /// must not fail the decode of the sibling window.
    struct Window: Decodable, Equatable, Sendable {
        /// A percentage, 0…100 — not a fraction. Nil means "usage unknown";
        /// it is never substituted with 0, which would claim a fact.
        var utilization: Double?
        /// Nil when absent, null, or not a timestamp we can parse. Such a
        /// window yields no `RateWindow` at all — `RateWindow.resetAt` is
        /// non-optional and load-bearing, and there is nothing to invent.
        var resetsAt: Date?

        private enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
            // A null decodes to nil on its own, but a malformed *string* still
            // throws from inside the decoder's date strategy. `try?` turns that
            // throw into "no reset instant" so the rest of the response — and
            // the sibling window in particular — survives.
            resetsAt = (try? container.decodeIfPresent(Date.self, forKey: .resetsAt)) ?? nil
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

        if let window = fiveHour, let resetAt = window.resetsAt {
            windows.append(
                RateWindow(
                    kind: .rollingFiveHours,
                    usedFraction: window.utilization.map { $0 / 100 },
                    resetAt: resetAt,
                    observedAt: observedAt
                )
            )
        }

        if let window = sevenDay, let resetAt = window.resetsAt {
            windows.append(
                RateWindow(
                    kind: .weekly,
                    usedFraction: window.utilization.map { $0 / 100 },
                    resetAt: resetAt,
                    observedAt: observedAt
                )
            )
        }

        return windows
    }
}
