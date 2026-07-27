import Combine
import Foundation

final class AppSettingsStore: ObservableObject {
    @Published var appMode: AppMode {
        didSet {
            defaults.set(appMode.rawValue, forKey: Self.appModeKey)
        }
    }

    private let defaults: UserDefaults
    private static let appModeKey = "appMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let rawValue = defaults.string(forKey: Self.appModeKey),
           let storedMode = AppMode(rawValue: rawValue) {
            appMode = storedMode
        } else {
            appMode = .menuBarAndWindow
        }
    }
}
