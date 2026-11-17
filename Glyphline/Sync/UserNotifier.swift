import Foundation
import UserNotifications

/// One session the attention controller is about to report.
struct WaitingAgent: Equatable, Sendable {
    var sessionID: String
    var title: String
    var repository: String
    var waitingSince: Date
}

/// Which surface a notification belongs to, carried as the request's category
/// so a click can be routed without parsing anything the user reads.
enum NotificationCategory: String {
    case agentsWaiting = "agents-waiting"
    case quotaRunway = "quota-runway"
    case sessionExpired = "session-expired"
    case creditBalance = "credit-balance"
}

/// Every notification the app sends.
///
/// A protocol rather than direct `UNUserNotificationCenter` calls so the rules
/// that decide *whether* to notify can be tested without the system
/// notification centre, a bundle, a permission prompt or a real delivery.
///
/// Display names, session titles and repository names are the only things that
/// cross this boundary. No cookie, session, organisation id, path or response
/// body reaches a notification.
protocol UserNotifier: Sendable {
    func notifySessionExpired(accountDisplayName: String) async
    func notifyAgentsWaiting(_ agents: [WaitingAgent], now: Date) async
    func notifyQuotaRunningOut(accountDisplayName: String, window: RateWindowID, timeToEmpty: TimeInterval) async
    /// `amount` and `balance` arrive already formatted in their own currency.
    func notifyCreditExpiring(accountDisplayName: String, amount: String, expiresIn: TimeInterval) async
    func notifyCreditLow(accountDisplayName: String, balance: String) async
    func notifyConsoleSessionExpired(accountDisplayName: String) async
}

/// The words, kept apart from delivery so they can be tested.
enum UserNotificationText {
    static func agentsWaiting(_ agents: [WaitingAgent], now: Date) -> (title: String, body: String) {
        if agents.count == 1, let agent = agents.first {
            let minutes = max(0, Int(now.timeIntervalSince(agent.waitingSince) / 60))
            if agent.repository.isEmpty {
                return (
                    agent.title,
                    String(
                        localized: "Waiting for you for \(minutes) min",
                        comment: "Notification body for one waiting agent whose repository is unknown. Placeholder: whole minutes waited."
                    )
                )
            }
            return (
                agent.title,
                String(
                    localized: "Waiting for you for \(minutes) min · \(agent.repository)",
                    comment: "Notification body for one waiting agent. Placeholders: whole minutes waited, then the repository name, which stays untranslated."
                )
            )
        }
        // The same key the dashboard's agents tile already carries.
        return (
            String(localized: "\(agents.count) agents are waiting on you"),
            agents.map(\.title).joined(separator: ", ")
        )
    }

    static func quotaRunningOut(window: RateWindowID, timeToEmpty: TimeInterval) -> String {
        String(
            localized: "\(window.longName) window empty in about \(QuotaIndicator.compactDuration(timeToEmpty)) at this pace",
            comment: "Notification body warning that a quota window will run out before it resets. Placeholders: the window's name such as '5-hour' or 'Weekly', then a duration such as '20m'."
        )
    }

    static func creditExpiring(amount: String, expiresIn: TimeInterval) -> String {
        String(
            localized: "\(amount) of API credit expires in \(QuotaIndicator.compactDuration(expiresIn))",
            comment: "Notification body warning that prepaid Claude Console API credit is about to lapse. Placeholders: a formatted money amount such as '$10.00', then a duration such as '2d'."
        )
    }

    static func creditLow(balance: String) -> String {
        String(
            localized: "API credit is down to \(balance)",
            comment: "Notification body warning that the prepaid Claude Console API credit balance is low. Placeholder: a formatted money amount such as '$4.00'."
        )
    }

    static var consoleSessionExpired: String {
        String(
            localized: "Your Claude Console sign-in has expired. Connect the Console again.",
            comment: "Notification body when the Claude Console (platform.claude.com) sign-in used to read API credit has expired."
        )
    }
}

/// The shipping implementation.
///
/// Constructing it touches nothing. `UNUserNotificationCenter.current()` is only
/// reached when there is something to say, so building a coordinator never asks
/// for permission it may never need.
struct SystemUserNotifier: UserNotifier {
    func notifySessionExpired(accountDisplayName: String) async {
        // The app's own constant, never a provider string.
        await deliver(title: accountDisplayName,
                      body: RateWindowSourceError.sessionExpired.message,
                      category: .sessionExpired)
    }

    func notifyAgentsWaiting(_ agents: [WaitingAgent], now: Date) async {
        guard !agents.isEmpty else { return }
        let text = UserNotificationText.agentsWaiting(agents, now: now)
        await deliver(title: text.title, body: text.body, category: .agentsWaiting)
    }

    func notifyQuotaRunningOut(accountDisplayName: String, window: RateWindowID, timeToEmpty: TimeInterval) async {
        await deliver(title: accountDisplayName,
                      body: UserNotificationText.quotaRunningOut(window: window, timeToEmpty: timeToEmpty),
                      category: .quotaRunway)
    }

    func notifyCreditExpiring(accountDisplayName: String, amount: String, expiresIn: TimeInterval) async {
        await deliver(title: accountDisplayName,
                      body: UserNotificationText.creditExpiring(amount: amount, expiresIn: expiresIn),
                      category: .creditBalance)
    }

    func notifyCreditLow(accountDisplayName: String, balance: String) async {
        await deliver(title: accountDisplayName,
                      body: UserNotificationText.creditLow(balance: balance),
                      category: .creditBalance)
    }

    func notifyConsoleSessionExpired(accountDisplayName: String) async {
        await deliver(title: accountDisplayName,
                      body: UserNotificationText.consoleSessionExpired,
                      category: .sessionExpired)
    }

    private func deliver(title: String, body: String, category: NotificationCategory) async {
        let center = UNUserNotificationCenter.current()

        // A refusal is a legitimate answer, not an error worth surfacing: every
        // one of these is also visible in the app.
        guard let granted = try? await center.requestAuthorization(options: [.alert]), granted else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category.rawValue

        try? await center.add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
