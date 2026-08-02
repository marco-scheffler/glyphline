import AppKit
import SwiftUI

/// The one way into the map, from wherever it is asked for.
///
/// The Agentverse is a window of its own — even the whole dashboard window at
/// its minimum width is well short of the 1690 points the scene was designed at
/// — so every entry point opens that window rather than taking a surface's own
/// space.
///
/// Opening it is three steps, not one, and the order matters: a menu bar app is
/// an accessory, an accessory's windows cannot come forward, so the app has to
/// become regular *before* the window is raised and be brought to the front
/// after. Each site that wrote the sequence out by hand was one site that could
/// drop a step — the app menu's entry had already dropped two, and opened the
/// map behind whatever the user was looking at.
///
/// The same shape as `SettingsLink`, which the three surfaces that open settings
/// all use: one call, no sequence to get wrong, and it lives beside the window
/// identifier and the activation rule it depends on rather than inside a view.
enum AgentverseLauncher {
    @MainActor static func open(using openWindow: OpenWindowAction) {
        AppActivationController.regulariseForWindow()
        openWindow(id: AppMode.agentverseWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
