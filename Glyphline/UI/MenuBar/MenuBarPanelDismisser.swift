import AppKit

/// Closing the menu bar panel behind a button that opens a window.
///
/// The panel does not close itself. `MenuBarExtra(.window)` dismisses on a click
/// outside itself and on nothing else, so a button inside it that opens the
/// dashboard left the panel hanging over the window it had just raised —
/// reported as "wenn ich Dashboard klicke, bleibt die Menubar Ansicht noch
/// ausgeklappt".
///
/// The macOS 26 SDK has no `MenuBarExtra` dismissal API; the only sanctioned
/// route is `@Environment(\.dismiss)`, which has a long history of being a no-op
/// inside a `.window`-styled extra. It could not be verified here either: the
/// panel is not reachable from the accessibility API, and it is not reachable in
/// process either — `performClick(nil)` on the status item's `NSStatusBarButton`,
/// a synthesised `mouseDown`, `NSApp.sendEvent`, `NSWindow.sendEvent` and the
/// cell's own `performClick` were all tried against a built app, and none of them
/// created the panel window at all. Its button carries no target and no action,
/// so there is nothing to send. An unverifiable `dismiss()` that reads plausibly
/// and does nothing is worse than no fix, so the panel's window is closed
/// outright instead — which depends on nothing being honoured.
///
/// Two steps, and the order is the whole point. At the moment the button is
/// pressed the panel is the key window — it has to be, to have received the
/// click — but `regulariseForWindow()` and `openWindow` both change which window
/// is key. So the panel is captured *before* the launcher runs and closed after.
enum MenuBarPanelDismisser {
    /// The window to close later, read before anything moves it.
    @MainActor
    static func capture() -> NSWindow? {
        NSApp.keyWindow
    }

    /// Closes what `capture()` found, unless it is one of the app's own windows.
    ///
    /// The guard is not defensive decoration. If the panel were ever *not* key,
    /// the captured window would be the dashboard, the map or settings, and an
    /// unguarded close would destroy the window the user was standing in — a far
    /// worse bug than the one being fixed.
    @MainActor
    static func close(_ window: NSWindow?) {
        guard let window else { return }
        guard mayClose(
            identifier: window.identifier?.rawValue,
            isClaimedSettingsWindow: window === AppActivationController.claimedSettingsWindow
        ) else { return }

        window.close()
    }

    /// The decision, as arithmetic over the two facts a window is reduced to at
    /// the boundary above — the same shape as
    /// `AppActivationController.policy(for:hasWindowNeedingRegularApp:)`, and for
    /// the same reason: it can be measured without a running window server.
    ///
    /// Not a second rule. Which windows are the app's own is already answered by
    /// `AppActivationController` for the activation policy, and this asks that
    /// same question rather than restating the list of window identifiers.
    static func mayClose(identifier: String?, isClaimedSettingsWindow: Bool) -> Bool {
        !isClaimedSettingsWindow
            && !AppActivationController.isWindowNeedingRegularApp(identifier: identifier)
    }
}
