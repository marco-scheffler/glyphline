import AppKit
import XCTest
@testable import Glyphline

/// The mode is changeable with none of the app's views on screen — ⌘-dragging
/// the status item out of the menu bar runs `MenuBarExtra(isInserted:)`'s setter
/// while the dashboard scene is suppressed and the panel's content does not
/// exist. `WindowActivationObserver` is what applies the policy there, and these
/// tests pin that it subscribes at all and that the value reaching the policy
/// layer is the new mode.
///
/// The policy layer is stood in for rather than driven: `AppActivationController`
/// talks to `NSApp`, and this process pins itself to `.prohibited` so a run puts
/// nothing on screen. What is asserted is the decision, not the side effect.
///
/// The assertions run immediately after assigning to the setting, which assumes
/// the sink runs synchronously on the assigning call stack. That holds because
/// the chain is `$appMode.sink` and nothing else; a `receive(on:)` there would
/// take these red for a reason the failure text will not mention.
@MainActor
final class WindowActivationObserverTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "GlyphlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    /// A recorder in place of `AppActivationController.apply(mode:excluding:)`.
    ///
    /// `@MainActor` so a `@MainActor @Sendable` closure may capture it: the seam
    /// is main-actor isolated because the policy layer it stands in for is.
    @MainActor
    private final class ApplyRecorder {
        private(set) var modes: [AppMode] = []

        func record(_ mode: AppMode, _ closing: NSWindow?) {
            modes.append(mode)
        }
    }

    /// `@Published` emits the current value on subscription, so constructing the
    /// observer is the launch-time application. This is what would fail if the
    /// subscription were made lazy or dropped.
    func testConstructingTheObserverAppliesTheCurrentMode() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        settings.appMode = .windowOnly
        let recorder = ApplyRecorder()

        let observer = WindowActivationObserver(
            settings: settings,
            applyPolicy: { mode, closing in recorder.record(mode, closing) }
        )
        withExtendedLifetime(observer) {
            XCTAssertEqual(
                recorder.modes, [.windowOnly],
                "constructing the observer must subscribe and apply at once; nothing recorded here means the first emission never arrived"
            )
        }
    }

    /// The hole this covers: with the dashboard scene suppressed and the panel
    /// closed, no view exists to react to the mode change, and an app left
    /// `.accessory` with no menu bar extra is recoverable only by force-quit.
    func testDraggingTheStatusItemOutAppliesTheNewMode() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        settings.appMode = .menuBarOnly
        let recorder = ApplyRecorder()

        let observer = WindowActivationObserver(
            settings: settings,
            applyPolicy: { mode, closing in recorder.record(mode, closing) }
        )
        withExtendedLifetime(observer) {
            XCTAssertEqual(recorder.modes, [.menuBarOnly], "precondition")

            // What `MenuBarExtra(isInserted:)`'s setter writes when the status
            // item is ⌘-dragged out of the menu bar.
            settings.appMode = .windowOnly

            XCTAssertEqual(
                recorder.modes, [.menuBarOnly, .windowOnly],
                "the mode change must reach the policy layer, and as the new mode: `@Published` publishes on `willSet`, so a sink that re-read the store would apply the mode being replaced and strand the app as an accessory with no menu bar extra"
            )
        }
    }

    /// The mirror, and the direction that matters on the way back: putting the
    /// status item back has to make the app an accessory again rather than
    /// re-apply the `windowOnly` being replaced.
    func testReturningToMenuBarOnlyAppliesThatMode() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        settings.appMode = .windowOnly
        let recorder = ApplyRecorder()

        let observer = WindowActivationObserver(
            settings: settings,
            applyPolicy: { mode, closing in recorder.record(mode, closing) }
        )
        withExtendedLifetime(observer) {
            settings.appMode = .menuBarOnly

            XCTAssertEqual(
                recorder.modes, [.windowOnly, .menuBarOnly],
                "the sink must use the value Combine passed it, not the one still in the store"
            )
        }
    }
}
