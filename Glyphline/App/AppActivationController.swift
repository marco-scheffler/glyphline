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
        NSApp.windows.contains { $0.isVisible && isWindowNeedingRegularApp($0) }
    }

    /// The settings window, as claimed by its own content view.
    ///
    /// Weak on purpose: this is a note about a window that exists, not a reason
    /// for it to keep existing. Once the window is gone the reference empties
    /// itself and the app can drop back to `.accessory`.
    @MainActor
    private(set) static weak var claimedSettingsWindow: NSWindow?

    /// Let the settings window identify itself instead of being recognised by
    /// name.
    ///
    /// `settingsWindowID` below is Apple's internal string, not API, and a major
    /// release is exactly where such a name changes. If it ever does, the
    /// identifier match goes quietly false and the symptom is obscure: switching
    /// to Menu Bar mode from inside settings closes the window the user is
    /// standing in. A window that has told us who it is cannot be renamed out
    /// from under us.
    @MainActor
    static func claimSettingsWindow(_ window: NSWindow?) {
        guard let window else { return }
        claimedSettingsWindow = window
    }

    /// The rule as it is actually applied, on a real window: the claim first,
    /// the identifier as the fallback for a window that never got to claim
    /// itself — a settings window restored before its content view is on screen,
    /// for one.
    @MainActor
    static func isWindowNeedingRegularApp(_ window: NSWindow) -> Bool {
        window === claimedSettingsWindow
            || isWindowNeedingRegularApp(identifier: window.identifier?.rawValue)
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
