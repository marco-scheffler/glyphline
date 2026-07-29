import Foundation
import UserNotifications

/// Told when an account's quota can no longer be read because its sign-in has
/// stopped working.
///
/// A protocol rather than a direct `UNUserNotificationCenter` call so the
/// notify-once rule can be tested without the system notification centre, and so
/// no test needs a bundle, a permission prompt, or a real delivery.
///
/// The account's display name is the only thing that crosses this boundary. No
/// cookie, no session, no organisation id and no response body reaches a
/// notification.
protocol QuotaNotifier: Sendable {
    func notifySessionExpired(accountDisplayName: String) async
}

/// The shipping implementation.
///
/// Constructing it touches nothing. `UNUserNotificationCenter.current()` is only
/// reached when there is actually something to say, so building a coordinator
/// never asks the user for permission it may never need.
struct UserNotificationQuotaNotifier: QuotaNotifier {
    func notifySessionExpired(accountDisplayName: String) async {
        let center = UNUserNotificationCenter.current()

        // A refusal is a legitimate answer, not an error worth surfacing: the
        // message is already on the account's row in the menu.
        guard let granted = try? await center.requestAuthorization(options: [.alert]), granted else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = accountDisplayName
        // The app's own constant, never a provider string.
        content.body = RateWindowSourceError.sessionExpired.message

        try? await center.add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
        )
    }
}
