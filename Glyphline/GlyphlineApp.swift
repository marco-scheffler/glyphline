import AppKit
import SwiftUI

@main
struct GlyphlineApp: App {
    @StateObject private var settings: AppSettingsStore
    @StateObject private var coordinator: SyncCoordinator
    @StateObject private var agentverse: AgentverseCoordinator
    @StateObject private var updates: UpdateController

    // Not `@StateObject`: neither publishes anything a view reads, and making
    // them observable would invite a view to depend on one.
    private let schedule: SyncScheduleController
    private let windowActivation: WindowActivationObserver
    private let localHistoryRebuild: LocalHistoryRebuildController

    init() {
        let settings = AppSettingsStore()
        _settings = StateObject(wrappedValue: settings)

        // The updater has to be able to put the app back the way the mode
        // setting wants it once it is done showing windows. It is handed that as
        // one closure rather than the whole settings object, so it can be built
        // and reasoned about without one.
        _updates = StateObject(
            wrappedValue: UpdateController {
                AppActivationController.apply(mode: settings.appMode)
            }
        )

        // One store for both coordinators: `makeDefault()` opens a fresh
        // `DatabaseQueue` and runs the migrations every time it is called, so a
        // second call would mean a second connection to the same file.
        let ledger = LedgerStore.makeDefault()

        // Deliberately no in-memory stand-in when the on-disk ledger cannot be
        // opened: the coordinator refuses to collect without a durable ledger and
        // says so, rather than crashing at launch or writing to a scratch file.
        //
        // Built as a local before it is wrapped: the schedule controller needs
        // the same instance, not a second one.
        // Built before both users of it, and told here — synchronously, from the
        // durable marker — whether a rebuild is coming. That is what makes the
        // exclusion a fact rather than a race: the flag is already true before
        // any window exists to start the ordinary scan.
        let localHistoryGate = LocalHistoryWriteGate(
            rebuildIsOutstanding: !settings.hasRebuiltLocalHistory
        )

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: KeychainStore(),
            registry: ProviderAdapterRegistry(),
            localHistoryGate: localHistoryGate
        )
        _coordinator = StateObject(wrappedValue: coordinator)

        // Owned here rather than by the window on purpose. The park rule needs a
        // sweep to remember whom the previous sweep had on track; a coordinator
        // created with the window would start every opening having forgotten,
        // and nothing would ever reach the pit lane.
        _agentverse = StateObject(
            wrappedValue: AgentverseCoordinator(ledger: ledger)
        )

        // Both are `@MainActor`, and `App.init` runs on the main actor.
        schedule = SyncScheduleController(settings: settings, coordinator: coordinator)
        windowActivation = WindowActivationObserver(settings: settings)

        // Here rather than on the dashboard's `task`, because in the default mode
        // no window opens at launch — the correction has to happen whether or not
        // one ever does. It starts detached work and returns immediately.
        localHistoryRebuild = LocalHistoryRebuildController(
            settings: settings,
            gate: localHistoryGate,
            ledger: ledger
        )
    }

    var body: some Scene {
        WindowGroup(id: AppMode.dashboardWindowID) {
            ModeAwareWindowRoot(settings: settings) {
                DashboardView()
                    .environmentObject(settings)
                    .environmentObject(coordinator)
                    // The dashboard's header counts waiting agents, so it needs
                    // the same coordinator the map window uses — not one of its
                    // own, which would forget who was on track last sweep.
                    .environmentObject(agentverse)
            }
        }
        .windowStyle(.titleBar)
        // Read once per launch. `windowOnly` has no menu bar extra and would
        // otherwise start with no surface at all; the flag is the one-time
        // exception that keeps a newly installed app from launching into
        // nothing but an unfamiliar menu bar symbol.
        //
        // This is what removes the old window sweep. `menuBarOnly` used to let
        // SwiftUI open the window and then close it again in `onAppear`, which
        // ran on every scene reappearance rather than only at launch and needed
        // an exemption list to keep from destroying the agentverse and settings
        // windows along with it.
        .defaultLaunchBehavior(settings.opensDashboardAtLaunch ? .presented : .suppressed)

        WindowGroup(id: AppMode.agentverseWindowID) {
            AgentverseWindow()
                .environmentObject(agentverse)
                // The office's windows need the stored weather reading and the
                // timestamp that throttles asking for a new one.
                .environmentObject(settings)
        }
        .defaultSize(width: 1_400, height: 820)
        .windowStyle(.titleBar)
        // Attached to the window it opens. Without it the map is reachable only
        // through the menu bar panel, and `.windowOnly` removes the menu bar
        // extra entirely — leaving that mode with no way in at all.
        .commands {
            // Directly under "About Glyphline", where macOS apps have kept this
            // item for twenty years. Somewhere findable matters more than usual
            // here: it is the only way to ask for an update on purpose.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }

            CommandGroup(after: .newItem) {
                OpenAgentverseCommand()
            }
        }

        // A real settings scene, so ⌘, and the app menu's Settings… item exist at
        // all — SwiftUI supplies neither without one. Accounts is a tab in here
        // rather than a place in the dashboard's sidebar: what is left of it is
        // management, which is configuration.
        Settings {
            SettingsRootView()
                .environmentObject(settings)
                // The accounts list draws each account's quota bars, from the
                // same coordinator every other surface reads.
                .environmentObject(coordinator)
                // General carries the update section, and its toggle reads the
                // updater's own defaults rather than a copy of them.
                .environmentObject(updates)
        }

        MenuBarExtra(isInserted: menuBarExtraInsertion) {
            ModeAwareMenuBarRoot(settings: settings) {
                MenuBarView()
                    .environmentObject(coordinator)
            }
        } label: {
            // One fixed mark: the icon no longer follows `quotaLight`. The state
            // lives in the panel that opens — its header dot and the tinted bar
            // on every row — so the menu bar keeps a single stable silhouette.
            //
            // `gauge.with.needle` is a placeholder for custom artwork (a minimal
            // gauge glyph, one arc plus one needle) that echoes the app icon. It
            // was picked as a stand-in, not as a considered final mark: swap the
            // custom asset in here.
            //
            // `Image`, not `Label`: a `Label` generally resolves to title *and*
            // icon, which would put the word "Glyphline" in the menu bar beside
            // the symbol. The name still reaches VoiceOver, through the
            // accessibility label rather than through rendered text.
            //
            // The accessibility label stays state-dependent on purpose — see
            // `QuotaIndicator.accessibilityLabel(for:)`.
            Image(systemName: QuotaIndicator.menuBarSymbolName)
                .accessibilityLabel(
                    Text(QuotaIndicator.accessibilityLabel(for: coordinator.quotaLight))
                )
        }
        // `.window`, not the default `.menu`: the content is a laid-out panel
        // with a fixed width, padding, tinted progress bars and bordered
        // buttons. A menu honours none of those — it renders its content as
        // menu items and cannot draw a progress bar at all.
        .menuBarExtraStyle(.window)
    }

    private var menuBarExtraInsertion: Binding<Bool> {
        Binding(
            get: {
                settings.appMode.showsMenuBarExtra
            },
            set: { isInserted in
                guard isInserted != settings.appMode.showsMenuBarExtra else {
                    return
                }

                settings.appMode = isInserted ? .menuBarOnly : .windowOnly
            }
        )
    }
}

/// The app menu's way into the map.
///
/// A view rather than a bare `Button` in the command group: `openWindow` is an
/// environment value, and a `Scene` has no environment to read it from.
///
/// Through `AgentverseLauncher` like every other entry point. It used to raise
/// the window on its own, without regularising the app first or activating it
/// after — in menu bar mode that opened the map behind the frontmost app, or
/// left it to be swept closed again.
///
/// ⌘⇧A is free — the app defines no shortcuts of its own, and the standard menus
/// SwiftUI supplies take ⌘A for Select All but nothing with Shift.
private struct OpenAgentverseCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Agentverse") {
            AgentverseLauncher.open(using: openWindow)
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}

private struct ModeAwareWindowRoot<Content: View>: View {
    @ObservedObject var settings: AppSettingsStore
    let content: () -> Content

    var body: some View {
        content()
            .onAppear {
                // Recorded the moment the window is actually on screen, which is
                // the only thing that makes the first-launch exception true
                // exactly once. A suppressed scene never reaches this.
                //
                // Guarded because the `didSet` has no equality check of its own:
                // an unguarded write on every reopening writes to `UserDefaults`
                // and publishes `objectWillChange` on the store, which
                // re-evaluates `App.body` for a value that did not change.
                if !settings.hasShownDashboardOnce {
                    settings.hasShownDashboardOnce = true
                }
                // Not `apply(mode:)`. This runs before the window is visible, so
                // the walk over `NSApp.windows` finds nothing and demotes the app
                // underneath the very window that is appearing. The dashboard
                // appearing *is* the reason to be regular — the same call
                // `DashboardLauncher` makes, for the same reason.
                //
                // Nothing is lost by not re-deriving here: `WindowActivationObserver`
                // sets the launch-time policy, and takes it back when the last
                // window closes.
                AppActivationController.regulariseForWindow()
            }
        // No `onChange(of: settings.appMode)`: `WindowActivationObserver`
        // subscribes to the mode for the life of the process, so a handler here
        // would be a second mechanism for one job — and it could only ever cover
        // the modes in which this view exists, which is the hole the observer was
        // widened to close.
    }
}

private struct ModeAwareMenuBarRoot<Content: View>: View {
    @ObservedObject var settings: AppSettingsStore
    let content: () -> Content

    var body: some View {
        content()
            .onAppear {
                AppActivationController.apply(mode: settings.appMode)
            }
        // Mode changes are `WindowActivationObserver`'s, as above.
    }
}
