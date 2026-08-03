import AppKit
import SwiftUI

/// The one way into the dashboard, from wherever it is asked for.
///
/// The same shape as `AgentverseLauncher`, and for the same reason: the order is
/// three steps and each site that wrote it out by hand was a site that could
/// drop one. A menu bar app is an accessory, an accessory's windows cannot come
/// forward, so the app has to become regular *before* the window is raised and
/// be brought to the front after.
///
/// What this replaces is worse than a dropped step. `MenuBarView.openDashboard`
/// used to write `settings.appMode = .menuBarAndWindow` to get a window that the
/// menu bar mode did not allow — a button silently changing a preference the
/// user had set, in order to do the thing its label promised.
enum DashboardLauncher {
    @MainActor static func open(using openWindow: OpenWindowAction) {
        AppActivationController.regulariseForWindow()
        openWindow(id: AppMode.dashboardWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
