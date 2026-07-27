import AppKit
import GRDB
import SwiftUI

@main
struct GlyphlineApp: App {
    @StateObject private var settings: AppSettingsStore
    @StateObject private var coordinator: SyncCoordinator

    init() {
        let settings = AppSettingsStore()
        _settings = StateObject(wrappedValue: settings)

        let ledger = LedgerStore.makeDefault()
        let estimator = CostEstimator(
            catalog: (try? PricingCatalog.bundled()) ?? PricingCatalog(entries: [])
        )
        _coordinator = StateObject(
            wrappedValue: SyncCoordinator(
                ledger: ledger ?? LedgerStore(dbQueue: try! DatabaseQueueFactory.makeInMemory()),
                credentials: KeychainStore(),
                registry: ProviderAdapterRegistry(),
                estimator: estimator
            )
        )
    }

    var body: some Scene {
        WindowGroup(id: AppMode.dashboardWindowID) {
            ModeAwareWindowRoot(settings: settings) {
                DashboardView()
                    .environmentObject(settings)
                    .environmentObject(coordinator)
            }
        }
        .windowStyle(.titleBar)

        MenuBarExtra(
            "Glyphline",
            systemImage: "chart.line.uptrend.xyaxis",
            isInserted: menuBarExtraInsertion
        ) {
            ModeAwareMenuBarRoot(settings: settings) {
                MenuBarView()
                    .environmentObject(settings)
                    .environmentObject(coordinator)
            }
        }
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
        }
        .onChange(of: settings.appMode) { _, newValue in
            AppActivationController.apply(mode: newValue)
            if !newValue.showsDashboardWindow {
                closeVisibleWindows()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
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
