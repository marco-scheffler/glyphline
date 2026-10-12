import Combine
import SwiftUI
import UserNotifications

enum NotificationDestination: Equatable {
    case agentverse
    case dashboard
}

/// Turns a click on a notification into a window.
///
/// The delegate has no `openWindow` — that is an environment value — so it only
/// records where the click asked to go, and the roots that do have one open it
/// through the existing launchers. Two roots may be listening at once (the menu
/// bar label and an open window), so a destination is consumed once.
///
/// A click stores its destination in `pending` first and then signals on
/// `deliveries`. A separate subject rather than `$pending`, because `@Published`
/// emits on willSet: a listener reacting to `$pending` would run before the
/// value is stored, and `consume()` would find nothing. The subject fires on
/// every click, so a repeat of the same category opens again.
///
/// In window-only mode with every window closed no root is alive to listen; the
/// destination stays pending, and the root that mounts next (the Dock icon
/// reopening a window) consumes it on appear — which is what the click asked for.
@MainActor
final class NotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var pending: NotificationDestination?
    /// Fires after `pending` holds a click's destination.
    let deliveries = PassthroughSubject<Void, Never>()

    static func destination(forCategory category: String) -> NotificationDestination? {
        switch NotificationCategory(rawValue: category) {
        case .agentsWaiting: .agentverse
        case .quotaRunway, .sessionExpired: .dashboard
        case nil: nil
        }
    }

    func route(category: String) {
        pending = Self.destination(forCategory: category)
        if pending != nil { deliveries.send(()) }
    }

    func consume() -> NotificationDestination? {
        defer { pending = nil }
        return pending
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let category = response.notification.request.content.categoryIdentifier
        await MainActor.run { route(category: category) }
    }

    /// Shown even while Glyphline is frontmost: a menu bar app is "frontmost"
    /// whenever its panel is open, which is exactly when a banner is still news.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

private struct NotificationDestinationListener: ViewModifier {
    @ObservedObject var router: NotificationRouter
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onReceive(router.deliveries) { open(router.consume()) }
            .onAppear { open(router.consume()) }
    }

    private func open(_ destination: NotificationDestination?) {
        switch destination {
        case .agentverse: AgentverseLauncher.open(using: openWindow)
        case .dashboard: DashboardLauncher.open(using: openWindow)
        case nil: break
        }
    }
}

extension View {
    func opensNotificationDestinations(from router: NotificationRouter) -> some View {
        modifier(NotificationDestinationListener(router: router))
    }
}
