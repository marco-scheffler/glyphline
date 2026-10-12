import Foundation
@testable import Glyphline

/// Records what was sent, not merely how often, so a test can prove *which*
/// account was named as well as the transition rule.
@MainActor
final class RecordingNotifier: UserNotifier {
    private(set) var sentNames: [String] = []
    private(set) var waitingBatches: [[WaitingAgent]] = []
    private(set) var runwayWarnings: [(name: String, kind: RateWindowKind, timeToEmpty: TimeInterval)] = []

    var sentCount: Int { sentNames.count }

    nonisolated func notifySessionExpired(accountDisplayName: String) async {
        await MainActor.run { sentNames.append(accountDisplayName) }
    }

    nonisolated func notifyAgentsWaiting(_ agents: [WaitingAgent], now: Date) async {
        await MainActor.run { waitingBatches.append(agents) }
    }

    nonisolated func notifyQuotaRunningOut(accountDisplayName: String, kind: RateWindowKind, timeToEmpty: TimeInterval) async {
        await MainActor.run { runwayWarnings.append((accountDisplayName, kind, timeToEmpty)) }
    }
}
