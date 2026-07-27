import SwiftUI

@main
struct GlyphlineApp: App {
    private let appMode: AppMode = .menuBarAndWindow

    var body: some Scene {
        // Task 7 will wire this mode into user-facing settings; both scenes stay visible now.
        WindowGroup {
            DashboardView()
        }
        .windowStyle(.titleBar)

        MenuBarExtra("Glyphline", systemImage: "chart.line.uptrend.xyaxis") {
            MenuBarView()
        }
    }
}
