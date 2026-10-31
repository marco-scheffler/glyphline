import Foundation

/// Decodes claude.ai's usage response.
///
/// The contract is `five_hour`, `seven_day`, and from `limits` only the weekly
/// allowances confined to one model, which appear nowhere else. The response
/// also carries internal codename fields (`tangelo`, `nimbus_quill`, …) that
/// are always null and may vanish, and billing fields (`spend`, `extra_usage`)
/// that belong to the cost ledger rather than here. Both are deliberately unread.
struct ClaudeUsageResponse: Decodable, Equatable, Sendable {
    /// Both fields are tolerated as absent, null or — for the date — malformed.
    /// A subscription with no active window reports no reset instant, and that
    /// must not fail the decode of the sibling window.
    struct Window: Decodable, Equatable, Sendable {
        /// A percentage, 0…100 — not a fraction. Nil means "usage unknown";
        /// it is never substituted with 0, which would claim a fact.
        var utilization: Double?
        /// Nil when absent, null, or not a timestamp we can parse. The window
        /// is still emitted, with no reset instant: `resets_at` is null on both
        /// windows of a subscription that has not been used yet — a rolling
        /// window only starts on first use — and `utilization` is a real number
        /// beside it. Dropping the window discarded "0% consumed" along with
        /// the absent instant, which is the most useful reading the endpoint
        /// produces.
        ///
        /// An unparseable timestamp lands in the same state as an explicit
        /// null. That is a deliberate loss of one distinction: the alternative
        /// is a third case whose only effect would be to discard a fraction the
        /// provider reported correctly.
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

    /// `limits`, read for one thing: a weekly allowance confined to a model.
    ///
    /// Its other entries repeat what `five_hour` and `seven_day` already say
    /// (`session`, `weekly_all`) and are not read twice. The list is the newest
    /// part of the response and has been seen as an empty *object*, so any
    /// shape other than a list of objects costs the model windows and nothing
    /// else — never the decode of the two windows beside it.
    struct ModelLimits: Decodable, Equatable, Sendable {
        struct Entry: Decodable, Equatable, Sendable {
            var kind: String?
            /// 0…100 of the model's own allowance, like `utilization`.
            var percent: Double?
            var resetsAt: Date?
            /// `scope.model.display_name`. The model's `id` is null in practice,
            /// so the name is the only handle there is.
            var model: String?

            private enum CodingKeys: String, CodingKey {
                case kind
                case percent
                case resetsAt = "resets_at"
                case scope
            }

            private enum ScopeKeys: String, CodingKey { case model }
            private enum ModelKeys: String, CodingKey { case displayName = "display_name" }

            /// Every field optional and every failure local, for the reason the
            /// windows above give: one odd value must not take its neighbours.
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
                percent = (try? container.decodeIfPresent(Double.self, forKey: .percent)) ?? nil
                resetsAt = (try? container.decodeIfPresent(Date.self, forKey: .resetsAt)) ?? nil
                let scope = try? container.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope)
                let model = try? scope?.nestedContainer(keyedBy: ModelKeys.self, forKey: .model)
                self.model = (try? model?.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
            }
        }

        var entries: [Entry]

        init(from decoder: any Decoder) throws {
            entries = (try? decoder.singleValueContainer().decode([Entry].self)) ?? []
        }
    }

    var fiveHour: Window?
    var sevenDay: Window?
    var limits: ModelLimits?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
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
    ///
    /// Only the *absence of the window object* drops a window. A window that is
    /// present keeps both of its facts exactly as reported, each independently
    /// optional: a null `utilization` becomes a nil `usedFraction`, and a null
    /// `resets_at` becomes a nil `resetAt`. Neither one suppresses the other,
    /// which is the whole change — requiring the instant used to discard the
    /// fraction beside it.
    func rateWindows(observedAt: Date) -> [RateWindow] {
        var windows: [RateWindow] = []

        if let window = fiveHour {
            windows.append(
                RateWindow(
                    kind: .rollingFiveHours,
                    usedFraction: window.utilization.map { $0 / 100 },
                    resetAt: window.resetsAt,
                    observedAt: observedAt
                )
            )
        }

        if let window = sevenDay {
            windows.append(
                RateWindow(
                    kind: .weekly,
                    usedFraction: window.utilization.map { $0 / 100 },
                    resetAt: window.resetsAt,
                    observedAt: observedAt
                )
            )
        }

        // A model's weekly allowance — Fable's, since the plans were renamed —
        // is a window of its own, named by the model. An entry naming no model
        // cannot be labelled, and a second entry for the same model would be a
        // second row claiming to be the same limit; both are skipped.
        var models: Set<String> = []
        for entry in limits?.entries ?? [] where entry.kind == "weekly_scoped" {
            guard let model = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty,
                  models.insert(model).inserted
            else { continue }

            windows.append(
                RateWindow(
                    kind: .weekly,
                    usedFraction: entry.percent.map { $0 / 100 },
                    resetAt: entry.resetsAt,
                    observedAt: observedAt,
                    model: model
                )
            )
        }

        return windows
    }
}
