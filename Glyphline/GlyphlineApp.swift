import AppKit
import SwiftUI

@main
struct GlyphlineApp: App {
    @StateObject private var settings: AppSettingsStore
    @StateObject private var coordinator: SyncCoordinator
    @StateObject private var agentverse: AgentverseCoordinator
    @StateObject private var updates: UpdateController

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
        _coordinator = StateObject(
            wrappedValue: SyncCoordinator(
                ledger: ledger,
                credentials: KeychainStore(),
                registry: ProviderAdapterRegistry()
            )
        )

        // Owned here rather than by the window on purpose. The park rule needs a
        // sweep to remember whom the previous sweep had on track; a coordinator
        // created with the window would start every opening having forgotten,
        // and nothing would ever reach the pit lane.
        _agentverse = StateObject(
            wrappedValue: AgentverseCoordinator(ledger: ledger)
        )
    }

    var body: some Scene {
        WindowGroup(id: AppMode.dashboardWindowID) {
            ModeAwareWindowRoot(settings: settings, coordinator: coordinator) {
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
                    .environmentObject(settings)
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

                settings.appMode = isInserted ? .menuBarAndWindow : .windowOnly
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
    @ObservedObject var coordinator: SyncCoordinator
    let content: () -> Content

    var body: some View {
        Group {
            if settings.appMode.showsDashboardWindow {
                content()
            } else {
                EmptyView()
            }
        }
        .onAppear {
            AppActivationController.apply(mode: settings.appMode)
            if !settings.appMode.showsDashboardWindow {
                closeVisibleWindows()
            }
            applyScheduler()
        }
        .onChange(of: settings.automaticSyncEnabled) { _, _ in applyScheduler() }
        .onChange(of: settings.syncIntervalMinutes) { _, _ in applyScheduler() }
        .onChange(of: settings.appMode) { _, newValue in
            AppActivationController.apply(mode: newValue)
            if !newValue.showsDashboardWindow {
                closeVisibleWindows()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// The coordinator ignores a re-application of the schedule it is already
    /// running, so `onAppear` firing again on scene recreation cannot push the
    /// next sync out by another full interval.
    private func applyScheduler() {
        coordinator.applySchedule(
            enabled: settings.automaticSyncEnabled,
            intervalSeconds: TimeInterval(settings.syncIntervalMinutes * 60)
        )
    }

    /// Closes the dashboard's windows when the mode says it has none.
    ///
    /// The agentverse window is exempt. It is not mode-aware — it opens in either
    /// mode — so an unfiltered sweep here does not hide it, it destroys it, on
    /// every switch to menu-bar-only and on every dashboard scene reappearance in
    /// that mode.
    private func closeVisibleWindows() {
        for window in NSApp.windows
        where window.isVisible
            && !AppActivationController.isWindowNeedingRegularApp(window) {
            window.close()
        }
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
            .onChange(of: settings.appMode) { _, newValue in
                AppActivationController.apply(mode: newValue)
            }
    }
}
