import Foundation
@testable import Glyphline

/// Records what was sent, not merely how often, so a test can prove *which*
/// account was named as well as the transition rule.
@MainActor
final class RecordingNotifier: UserNotifier {
    private(set) var sentNames: [String] = []
    private(set) var waitingBatches: [[WaitingAgent]] = []
    private(set) var runwayWarnings: [(name: String, window: RateWindowID, timeToEmpty: TimeInterval)] = []

    var sentCount: Int { sentNames.count }

    nonisolated func notifySessionExpired(accountDisplayName: String) async {
        await MainActor.run { sentNames.append(accountDisplayName) }
    }

    nonisolated func notifyAgentsWaiting(_ agents: [WaitingAgent], now: Date) async {
        await MainActor.run { waitingBatches.append(agents) }
    }

    nonisolated func notifyQuotaRunningOut(accountDisplayName: String, window: RateWindowID, timeToEmpty: TimeInterval) async {
        await MainActor.run { runwayWarnings.append((accountDisplayName, window, timeToEmpty)) }
    }

    private(set) var creditExpiring: [(name: String, amount: String, expiresIn: TimeInterval)] = []
    private(set) var creditLow: [(name: String, balance: String)] = []
    private(set) var consoleExpired: [String] = []

    nonisolated func notifyCreditExpiring(accountDisplayName: String, amount: String, expiresIn: TimeInterval) async {
        await MainActor.run { creditExpiring.append((accountDisplayName, amount, expiresIn)) }
    }

    nonisolated func notifyCreditLow(accountDisplayName: String, balance: String) async {
        await MainActor.run { creditLow.append((accountDisplayName, balance)) }
    }

    nonisolated func notifyConsoleSessionExpired(accountDisplayName: String) async {
        await MainActor.run { consoleExpired.append(accountDisplayName) }
    }
}
