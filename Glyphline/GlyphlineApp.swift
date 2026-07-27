import AppKit
import SwiftUI

@main
struct GlyphlineApp: App {
    @StateObject private var settings: AppSettingsStore

    init() {
        let settings = AppSettingsStore()
        _settings = StateObject(wrappedValue: settings)
    }

    var body: some Scene {
        WindowGroup {
            ModeAwareWindowRoot(settings: settings) {
                DashboardView()
                    .environmentObject(settings)
            }
        }
        .windowStyle(.titleBar)

        MenuBarExtra("Glyphline", systemImage: "chart.line.uptrend.xyaxis") {
            ModeAwareMenuBarRoot(settings: settings) {
                MenuBarView()
                    .environmentObject(settings)
            }
        }
    }
}

private struct ModeAwareWindowRoot<Content: View>: View {
    @ObservedObject var settings: AppSettingsStore
    let content: () -> Content

    var body: some View {
        Group {
            if settings.appMode == .menuBarOnly {
                EmptyView()
            } else {
                content()
            }
        }
        .onAppear {
            AppActivationController.apply(mode: settings.appMode)
            if settings.appMode == .menuBarOnly {
                closeVisibleWindows()
            }
        }
        .onChange(of: settings.appMode) { _, newValue in
            AppActivationController.apply(mode: newValue)
            if newValue == .menuBarOnly {
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
        Group {
            if settings.appMode == .windowOnly {
                EmptyView()
            } else {
                content()
            }
        }
        .onAppear {
            AppActivationController.apply(mode: settings.appMode)
        }
        .onChange(of: settings.appMode) { _, newValue in
            AppActivationController.apply(mode: newValue)
        }
    }
}
