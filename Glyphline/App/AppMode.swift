import Foundation

enum AppMode: String, CaseIterable, Identifiable {
    static let dashboardWindowID = "dashboard"

    /// The map's own window. Separate from the dashboard because the two are read
    /// differently: the dashboard is opened, read and closed, while the map is
    /// left running beside the work.
    static let agentverseWindowID = "agentverse"

    case menuBarOnly
    case windowOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .menuBarOnly:
            String(
                localized: "Menu Bar",
                comment: "App mode picker segment: Glyphline lives in the menu bar."
            )
        case .windowOnly:
            String(
                localized: "Window",
                comment: "App mode picker segment: Glyphline behaves like a standard Mac app."
            )
        }
    }

    var showsMenuBarExtra: Bool {
        self == .menuBarOnly
    }

    /// Whether the dashboard comes up on its own at launch.
    ///
    /// This is all that is left of the removed `menuBarAndWindow` case. Once the
    /// Dock icon follows the open windows rather than the mode, "has a window"
    /// stopped being a property of the mode at all — the dashboard is openable
    /// in both — and the only thing still separating the two is whether it
    /// arrives without being asked for.
    ///
    /// `windowOnly` must, because it carries no menu bar extra: launching it
    /// without a window would leave the app with no surface to reach it by.
    var opensDashboardAtLaunch: Bool {
        self == .windowOnly
    }
}
