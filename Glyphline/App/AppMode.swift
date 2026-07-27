import Foundation

enum AppMode: String, CaseIterable, Identifiable {
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
}
