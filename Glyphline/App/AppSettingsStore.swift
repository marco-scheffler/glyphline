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

    /// The last sky we managed to read, kept across launches so an offline start
    /// shows what the weather was rather than snapping to a default that looks
    /// exactly like real data.
    @Published var lastWeather: Weather? {
        didSet {
            defaults.set(lastWeather?.rawValue, forKey: Self.lastWeatherKey)
        }
    }

    /// When `lastWeather` was read. Stored alongside it because the throttle is
    /// what keeps this to one request an hour, and a throttle that forgets across
    /// launches is no throttle at all.
    @Published var lastWeatherFetch: Date? {
        didSet {
            defaults.set(lastWeatherFetch, forKey: Self.lastWeatherFetchKey)
        }
    }

    /// The sky to draw with right now: the stored reading, or clear if there has
    /// never been one.
    var currentWeather: Weather {
        lastWeather ?? .clear
    }

    private let defaults: UserDefaults
    private static let appModeKey = "appMode"
    private static let automaticSyncEnabledKey = "automaticSyncEnabled"
    private static let syncIntervalMinutesKey = "syncIntervalMinutes"
    private static let lastWeatherKey = "lastWeather"
    private static let lastWeatherFetchKey = "lastWeatherFetch"

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

        // An unreadable stored value is treated as no value: better an honest
        // "never read" than a weather that came out of a corrupt default.
        lastWeather = defaults.string(forKey: Self.lastWeatherKey).flatMap(Weather.init(rawValue:))
        lastWeatherFetch = defaults.object(forKey: Self.lastWeatherFetchKey) as? Date
    }
}
