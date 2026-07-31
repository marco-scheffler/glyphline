import AppKit
import SwiftUI

@main
struct GlyphlineApp: App {
    @StateObject private var settings: AppSettingsStore
    @StateObject private var coordinator: SyncCoordinator
    @StateObject private var agentverse: AgentverseCoordinator

    init() {
        let settings = AppSettingsStore()
        _settings = StateObject(wrappedValue: settings)

        // Deliberately no in-memory stand-in when the on-disk ledger cannot be
        // opened: the coordinator refuses to collect without a durable ledger and
        // says so, rather than crashing at launch or writing to a scratch file.
        _coordinator = StateObject(
            wrappedValue: SyncCoordinator(
                ledger: LedgerStore.makeDefault(),
                credentials: KeychainStore(),
                registry: ProviderAdapterRegistry()
            )
        )

        // Owned here rather than by the window on purpose. The park rule needs a
        // sweep to remember whom the previous sweep had on track; a coordinator
        // created with the window would start every opening having forgotten,
        // and nothing would ever reach the pit lane.
        _agentverse = StateObject(
            wrappedValue: AgentverseCoordinator(ledger: LedgerStore.makeDefault())
        )
    }

    var body: some Scene {
        WindowGroup(id: AppMode.dashboardWindowID) {
            ModeAwareWindowRoot(settings: settings, coordinator: coordinator) {
                DashboardView()
                    .environmentObject(settings)
                    .environmentObject(coordinator)
            }
        }
        .windowStyle(.titleBar)

        WindowGroup(id: AppMode.agentverseWindowID) {
            AgentverseWindow()
                .environmentObject(agentverse)
        }
        .defaultSize(width: 1_400, height: 820)
        .windowStyle(.titleBar)

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

    private func closeVisibleWindows() {
        for window in NSApp.windows where window.isVisible {
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
