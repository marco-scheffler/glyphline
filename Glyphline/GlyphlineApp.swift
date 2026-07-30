import AppKit
import SwiftUI

@main
struct GlyphlineApp: App {
    @StateObject private var settings: AppSettingsStore
    @StateObject private var coordinator: SyncCoordinator

    init() {
        let settings = AppSettingsStore()
        _settings = StateObject(wrappedValue: settings)

        let estimator = CostEstimator(
            catalog: (try? PricingCatalog.bundled()) ?? PricingCatalog(entries: [])
        )
        // Deliberately no in-memory stand-in when the on-disk ledger cannot be
        // opened: the coordinator refuses to sync without a durable ledger and
        // says so, rather than crashing at launch or writing to a scratch file.
        let ledger = LedgerStore.makeDefault()
        _coordinator = StateObject(
            wrappedValue: SyncCoordinator(
                ledger: ledger,
                credentials: KeychainStore(),
                registry: ProviderAdapterRegistry(watermarkStore: ledger),
                estimator: estimator
            )
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

        MenuBarExtra(isInserted: menuBarExtraInsertion) {
            ModeAwareMenuBarRoot(settings: settings) {
                MenuBarView()
                    .environmentObject(settings)
                    .environmentObject(coordinator)
            }
        } label: {
            // The icon *is* the light: it follows `quotaLight` rather than
            // staying fixed.
            //
            // `Image`, not `Label`: a `Label` generally resolves to title *and*
            // icon, which would put the word "Glyphline" in the menu bar beside
            // the symbol. The name still reaches VoiceOver, through the
            // accessibility label rather than through rendered text.
            Image(systemName: QuotaIndicator.symbolName(for: coordinator.quotaLight))
                .accessibilityLabel(
                    Text(QuotaIndicator.accessibilityLabel(for: coordinator.quotaLight))
                )
        }
        // `.window`, not the default `.menu`: the content is a laid-out panel
        // with a fixed width, padding, a segmented picker and bordered buttons.
        // A menu honours none of those — it renders its content as menu items,
        // shows a picker as a bare checkmark and cannot draw a progress bar at
        // all.
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
