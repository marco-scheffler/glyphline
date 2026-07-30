import Foundation

/// Parses the timestamps in a Claude Code transcript.
///
/// Transcript timestamps carry fractional seconds, which `ISO8601DateFormatter`
/// rejects unless `.withFractionalSeconds` is set — hence the second, plain
/// formatter as a fallback.
///
/// A short-lived value owned by a single call, because `ISO8601DateFormatter` is
/// not `Sendable`: a shared static instance would need an unsafe opt-out, while
/// building one per line would dominate a parse that runs to millions of them.
struct TranscriptTimestampParser {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}
