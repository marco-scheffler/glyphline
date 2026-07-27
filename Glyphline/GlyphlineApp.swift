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
            }
        }
        .windowStyle(.titleBar)

        MenuBarExtra("Glyphline", systemImage: "chart.line.uptrend.xyaxis") {
            // The menu bar scene stays declared for all modes; Task 7 will move this behind user-facing settings.
            ModeAwareMenuBarRoot(settings: settings) {
                MenuBarView()
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
                NSApp.keyWindow?.close()
            }
        }
        .onChange(of: settings.appMode) { _, newValue in
            AppActivationController.apply(mode: newValue)
            if newValue == .menuBarOnly {
                NSApp.keyWindow?.close()
            }
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
