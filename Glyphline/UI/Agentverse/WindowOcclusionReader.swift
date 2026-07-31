import AppKit
import SwiftUI

/// Reports whether the window this view sits in is actually on screen.
///
/// The map is meant to be left running beside the work, so the question it has
/// to answer is not "is my app frontmost" — `scenePhase` answers that, and on
/// macOS a fully visible window in a background app reports `.inactive`, which
/// froze the map the moment the user clicked into their editor. The question is
/// whether any pixel of the window is on a screen someone could be looking at,
/// and `NSWindow.occlusionState` is the API macOS provides for exactly that:
/// it drops `.visible` when the window is minimised, hidden, on another Space,
/// or completely covered by another window, and keeps it when the window is
/// merely not frontmost.
///
/// The window is taken from `view.window` rather than looked up in
/// `NSApp.windows`: a search would have to guess which of several windows this
/// view belongs to, and the answer is already sitting in the view hierarchy.
struct WindowOcclusionReader: NSViewRepresentable {
    /// Set by the probe whenever the hosting window's occlusion changes.
    @Binding var isOnScreen: Bool

    func makeNSView(context: Context) -> WindowOcclusionProbeView {
        let view = WindowOcclusionProbeView()
        view.report = { self.isOnScreen = $0 }
        return view
    }

    func updateNSView(_ nsView: WindowOcclusionProbeView, context: Context) {
        // The binding is a fresh value on every rebuild, so the stored closure
        // has to be replaced or the probe would write into a stale one.
        nsView.report = { self.isOnScreen = $0 }
    }
}

/// The zero-sized `NSView` that does the observing.
///
/// A view and not a window delegate: the map's window belongs to SwiftUI, which
/// installs its own delegate, and replacing it would break whatever SwiftUI does
/// through it.
final class WindowOcclusionProbeView: NSView {
    var report: ((Bool) -> Void)?
    /// Kept so the observation can be torn off the *previous* window: a view can
    /// be moved between windows, and an observer left on the old one would keep
    /// reporting its occlusion as if it were ours.
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeOcclusionStateNotification, object: observedWindow
            )
        }
        observedWindow = window
        if let window {
            // Selector-based rather than a block observer: the callback lands on
            // this `@MainActor` view directly, so there is no closure crossing an
            // isolation boundary and nothing to silence with an unsafe opt-out.
            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionStateChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
        }
        publish()
        // The view is placed in the window before the window is ordered on
        // screen, so the reading above is still "not visible" and the change to
        // visible may land before the observer is armed. One more reading on the
        // next turn of the run loop catches that opening frame.
        Task { @MainActor in self.publish() }
    }

    @objc private func occlusionStateChanged() {
        publish()
    }

    private func publish() {
        report?(WindowVisibility.isOnScreen(isVisible: window?.isVisible ?? false,
                                            occlusion: window?.occlusionState ?? []))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// The rule itself, split out from the view so a test can pin it without a
/// window on screen.
enum WindowVisibility {
    /// Whether a window with this state is worth drawing for.
    ///
    /// Both halves are needed. `isVisible` is false for a closed, minimised or
    /// app-hidden window; `occlusionState` is what falls away when the window is
    /// still "visible" as far as AppKit's window list is concerned but no pixel
    /// of it reaches a screen — fully covered by another window, or on a Space
    /// the user has switched away from. Neither says anything about which app is
    /// frontmost, which is the whole point.
    static func isOnScreen(isVisible: Bool, occlusion: NSWindow.OcclusionState) -> Bool {
        isVisible && occlusion.contains(.visible)
    }
}
