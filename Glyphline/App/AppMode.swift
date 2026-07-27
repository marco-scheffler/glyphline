import Foundation

enum AppMode: String, CaseIterable, Identifiable {
    static let dashboardWindowID = "dashboard"

    case menuBarOnly
    case windowOnly
    case menuBarAndWindow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .menuBarOnly:
            "Menu Bar"
        case .windowOnly:
            "Window"
        case .menuBarAndWindow:
            "Both"
        }
    }

    var showsMenuBarExtra: Bool {
        self != .windowOnly
    }

    var showsDashboardWindow: Bool {
        self != .menuBarOnly
    }

    func requiresDashboardOpen(afterTransitioningFrom previousMode: AppMode) -> Bool {
        showsDashboardWindow && !previousMode.showsDashboardWindow
    }
}
