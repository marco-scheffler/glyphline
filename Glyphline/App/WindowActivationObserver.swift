import AppKit
import Combine

/// Puts the app back to `.accessory` when the last window that needed a regular
/// app goes away, and sets the launch-time policy.
///
/// The way back did not exist before. `regulariseForWindow()` set `.regular` and
/// nothing took it back, except that the menu bar panel's `onAppear` happened to
/// call `apply(mode:)` the next time the user opened it — so the Dock icon
/// outlived the window that justified it, for as long as nobody touched the
/// panel.
///
/// `willCloseNotification` fires while the window is still in `NSApp.windows`
/// and still reports `isVisible`, which is why the closing window is passed to
/// `excluding:` rather than the walk being left to notice it has gone.
///
/// Subscribed without `receive(on:)` on purpose: `NSWindow` notifications are
/// posted on the main thread already, so there is no hop, and therefore no
/// non-`Sendable` `NSWindow` crossing an isolation boundary.
@MainActor
final class WindowActivationObserver {
    private var cancellable: AnyCancellable?

    init(settings: AppSettingsStore) {
        // The launch-time policy. A bundled app starts `.regular`, so without
        // this the default mode carries a Dock icon from launch until the user
        // first opens the menu bar panel.
        //
        // `NSApplication.shared` first, and it is not decorative: this runs from
        // `App.init`, which SwiftUI calls before the global `NSApp` has been
        // populated. Reading `NSApp.windows` there is a crash on an
        // implicitly-unwrapped nil — observed, not theoretical. `shared` creates
        // the instance and sets `NSApp` as a side effect.
        _ = NSApplication.shared
        AppActivationController.apply(mode: settings.appMode)

        cancellable = NotificationCenter.default
            .publisher(for: NSWindow.willCloseNotification)
            .sink { notification in
                MainActor.assumeIsolated {
                    AppActivationController.apply(
                        mode: settings.appMode,
                        excluding: notification.object as? NSWindow
                    )
                }
            }
    }
}
