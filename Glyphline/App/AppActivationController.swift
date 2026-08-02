import AppKit

enum AppActivationController {
    @MainActor
    static func apply(mode: AppMode) {
        // The agentverse window overrides the stored mode. It opens in either
        // mode and never writes `appMode`, so without this the mode's own policy
        // would demote the app back to `.accessory` under a window that is still
        // on screen — taking away its Dock icon and any way back to it.
        let policy: NSApplication.ActivationPolicy =
            mode == .menuBarOnly && !hasWindowNeedingRegularApp() ? .accessory : .regular
        NSApp.setActivationPolicy(policy)
    }

    /// Make the app behave like an app with a window, without touching the stored
    /// `appMode`.
    ///
    /// `apply(mode:)` derives the policy from the setting, so the only way to
    /// regularise through it is to change the setting. The agentverse window opens
    /// in either mode and must not rewrite the user's choice — but an accessory app
    /// opening a window gets a window that never becomes key, has no Dock icon, and
    /// cannot be reached again once it loses focus, which from outside looks exactly
    /// like a button that does nothing.
    @MainActor
    static func regulariseForWindow() {
        NSApp.setActivationPolicy(.regular)
    }

    /// Whether a window is on screen that the app has to stay `.regular` for.
    @MainActor
    static func hasWindowNeedingRegularApp() -> Bool {
        NSApp.windows.contains { window in
            window.isVisible && isWindowNeedingRegularApp(identifier: window.identifier?.rawValue)
        }
    }

    /// The identifier SwiftUI gives the window its `Settings` scene opens. Not a
    /// scene id of ours — the framework names that window itself.
    static let settingsWindowID = "com_apple_SwiftUI_Settings_window"

    /// Split out from the `NSApp` walk so the matching rule can be tested without a
    /// running window.
    ///
    /// Prefix, not equality: SwiftUI derives the `NSWindow` identifier from the
    /// scene id and appends its own counter — the agentverse window comes up as
    /// `agentverse-AppWindow-1`, verified against a built app rather than assumed.
    ///
    /// The settings window is here for both of the things this predicate decides.
    /// It opens in every mode, including `.menuBarOnly` where the app is an
    /// accessory — so the app has to stay regular while it is up. And it carries
    /// the app-mode picker: without the exemption, switching to Menu Bar from
    /// inside settings would have the dashboard's window sweep close the very
    /// window the user was working in.
    static func isWindowNeedingRegularApp(identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier.hasPrefix(AppMode.agentverseWindowID)
            || identifier.hasPrefix(settingsWindowID)
    }
}
