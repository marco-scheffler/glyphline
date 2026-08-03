import AppKit
import Combine

/// Puts the app back to `.accessory` when the last window that needed a regular
/// app goes away, sets the launch-time policy, and applies every later change of
/// `appMode`.
///
/// The mode subscription lives here rather than in a view because there are ways
/// to change the mode with no view of ours on screen at all: ⌘-dragging the
/// status item out of the menu bar runs `MenuBarExtra(isInserted:)`'s setter,
/// and in the default mode with no window open the dashboard scene is suppressed
/// and the menu bar panel's content does not exist. The app would be left an
/// accessory with no menu bar extra, no Dock icon and no window — force-quit or
/// nothing. This object is built in `App.init` and lives as long as the process,
/// so it is there whether or not any scene is.
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
    private var cancellables: Set<AnyCancellable> = []

    /// - Parameter applyPolicy: the seam the tests stand in. Production passes
    ///   nothing and gets `AppActivationController.apply(mode:excluding:)`; a
    ///   test can record what reaches the policy layer without `NSApp` being
    ///   driven, which matters because the test process pins itself to
    ///   `.prohibited` so a run puts nothing on screen.
    init(
        settings: AppSettingsStore,
        applyPolicy: @escaping @MainActor (AppMode, NSWindow?) -> Void = { mode, closing in
            AppActivationController.apply(mode: mode, excluding: closing)
        }
    ) {
        // `@Published` emits the current value on subscription, so this is also
        // the launch-time policy — a bundled app starts `.regular`, and without
        // it the default mode would carry a Dock icon from launch until the user
        // first opened the menu bar panel. Initial application and every later
        // change are one code path rather than two that can drift.
        //
        // The sink uses the value Combine hands it and never re-reads
        // `settings.appMode`: `@Published` publishes on `willSet`, so a re-read
        // sees the value being replaced and the policy would be one change
        // behind forever. Same trap `SyncScheduleController` documents.
        settings.$appMode
            .sink { mode in
                MainActor.assumeIsolated {
                    applyPolicy(mode, nil)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSWindow.willCloseNotification)
            .sink { notification in
                MainActor.assumeIsolated {
                    applyPolicy(
                        settings.appMode,
                        notification.object as? NSWindow
                    )
                }
            }
            .store(in: &cancellables)
    }
}
