import Combine
import Foundation

final class AppSettingsStore: ObservableObject {
    @Published var appMode: AppMode {
        didSet {
            defaults.set(appMode.rawValue, forKey: Self.appModeKey)
        }
    }

    @Published var automaticSyncEnabled: Bool {
        didSet {
            defaults.set(automaticSyncEnabled, forKey: Self.automaticSyncEnabledKey)
        }
    }

    @Published var syncIntervalMinutes: Int {
        didSet {
            defaults.set(syncIntervalMinutes, forKey: Self.syncIntervalMinutesKey)
        }
    }

    private let defaults: UserDefaults
    private static let appModeKey = "appMode"
    private static let automaticSyncEnabledKey = "automaticSyncEnabled"
    private static let syncIntervalMinutesKey = "syncIntervalMinutes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let rawValue = defaults.string(forKey: Self.appModeKey),
           let storedMode = AppMode(rawValue: rawValue) {
            appMode = storedMode
        } else {
            appMode = .menuBarAndWindow
        }

        // `defaults.bool` reports false for an absent key, so the explicit
        // presence check is what makes "enabled by default" survive a fresh install.
        if defaults.object(forKey: Self.automaticSyncEnabledKey) == nil {
            automaticSyncEnabled = true
        } else {
            automaticSyncEnabled = defaults.bool(forKey: Self.automaticSyncEnabledKey)
        }

        let storedInterval = defaults.integer(forKey: Self.syncIntervalMinutesKey)
        syncIntervalMinutes = storedInterval > 0 ? storedInterval : 30
    }
}
