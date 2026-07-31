import AppKit

enum AppActivationController {
    @MainActor
    static func apply(mode: AppMode) {
        let policy: NSApplication.ActivationPolicy = mode == .menuBarOnly ? .accessory : .regular
        NSApp.setActivationPolicy(policy)
    }

    /// Make the app behave like an app with a window, without touching the stored
    /// `appMode`.
    ///
    /// `apply(mode:)` cannot express this: it derives the policy from the setting,
    /// so the only way to regularise through it is to change the setting. The
    /// agentverse window opens in either mode and must not rewrite the user's
    /// choice — but an accessory app opening a window gets a window that never
    /// becomes key, has no Dock icon, and cannot be reached again once it loses
    /// focus, which from outside looks exactly like a button that does nothing.
    @MainActor
    static func regulariseForWindow() {
        NSApp.setActivationPolicy(.regular)
    }
}
