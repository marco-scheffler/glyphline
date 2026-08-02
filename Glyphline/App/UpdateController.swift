import AppKit
import Combine
import Sparkle
import SwiftUI

/// Glyphline's updater: the app asking whether a newer Glyphline exists, and
/// installing it if the user says so.
///
/// A thin shell around Sparkle rather than a reimplementation of it. What sits
/// underneath — fetching a feed, verifying an EdDSA signature over the download,
/// swapping a running app bundle out from under itself — is the part of this
/// feature where a mistake hands strangers a way to run code on someone's Mac.
///
/// Two things this deliberately does not do:
///
/// **It never installs without a click.** Sparkle can download and install in
/// the background, and for an app that reads your quota data that is the wrong
/// default. `automaticallyDownloadsUpdates` stays off; the checking is
/// automatic, the installing is not.
///
/// **It does not store its own copy of the settings.** Whether checks are
/// automatic lives in Sparkle's own defaults (`SUEnableAutomaticChecks`), read
/// and written through the updater. A mirror of it in `AppSettingsStore` would
/// be a second source of truth for one fact, and the two would drift the first
/// time Sparkle wrote its own key.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    /// False while a check is already in flight, so the menu item and the button
    /// can go grey instead of queueing a second one behind the first.
    @Published private(set) var canCheckForUpdates = false

    /// Puts the app back the way the user's mode setting wants it, once the
    /// update session is over.
    ///
    /// Injected rather than read from `AppSettingsStore` here: what this type
    /// needs is one call at the end of a session, not an observable dependency
    /// on the whole settings object.
    private let restoreActivation: @MainActor () -> Void

    /// Assigned after `super.init()` — this object is its own user driver
    /// delegate, and `self` is not available to pass until then.
    private var updaterController: SPUStandardUpdaterController!

    init(restoreActivation: @escaping @MainActor () -> Void) {
        self.restoreActivation = restoreActivation
        super.init()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )

        // Explicit rather than left to the default: this is the line that keeps
        // "check automatically" from quietly meaning "install automatically".
        updaterController.updater.automaticallyDownloadsUpdates = false

        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Whether Glyphline looks for updates on its own. Sparkle asks the user
    /// once, on the first launch that has an updater in it; this is where they
    /// change their mind afterwards.
    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// The user asking, from the menu or from Settings.
    func checkForUpdates() {
        bringAppForward()
        updaterController.checkForUpdates(nil)
    }

    /// Make sure whatever Sparkle is about to put on screen can actually be seen.
    ///
    /// In menu-bar-only mode the process runs as `.accessory`, and a window
    /// opened by an accessory app never becomes key and cannot be raised — the
    /// update prompt would sit behind everything with no way to reach it, which
    /// from outside is indistinguishable from an updater that does nothing. The
    /// settings and agentverse windows take these same two steps for the same
    /// reason.
    private func bringAppForward() {
        AppActivationController.regulariseForWindow()
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Sparkle telling us when it is about to show something, and when it has
/// finished. Both halves matter: without the first the prompt is invisible in
/// menu bar mode, and without the second the app keeps a Dock icon it was not
/// meant to have for the rest of the session.
extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated { bringAppForward() }
    }

    nonisolated func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated { bringAppForward() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { restoreActivation() }
    }
}
