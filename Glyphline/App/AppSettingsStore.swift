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

    /// Which picture the Agentverse window shows.
    @Published var agentverseView: AgentverseView {
        didSet {
            defaults.set(agentverseView.rawValue, forKey: Self.agentverseViewKey)
        }
    }

    /// The latitude the user typed in, if they typed one. Nil means "use the
    /// time zone", which is the default and what almost everyone will leave it on.
    @Published var manualLatitude: Double? {
        didSet {
            setOrRemove(manualLatitude, forKey: Self.manualLatitudeKey)
        }
    }

    /// The longitude the user typed in, if they typed one.
    @Published var manualLongitude: Double? {
        didSet {
            setOrRemove(manualLongitude, forKey: Self.manualLongitudeKey)
        }
    }

    /// The override to hand `UserPlace.current`, or nil to fall back to the time
    /// zone. Both halves are required: a latitude alone paired with a default
    /// longitude of zero would silently light the office from Greenwich.
    var placeOverride: UserPlace.Coordinates? {
        guard let manualLatitude, let manualLongitude else { return nil }
        return UserPlace.Coordinates(latitude: manualLatitude,
                                     longitude: manualLongitude,
                                     source: .manual)
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
    private static let agentverseViewKey = "agentverseView"
    private static let manualLatitudeKey = "manualLatitude"
    private static let manualLongitudeKey = "manualLongitude"

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

        // Deliberately not `init(rawValue:)!`: a stored string outlives the case
        // that wrote it, so a renamed or removed case would trap here, on the
        // launch path, with no way out but deleting preferences.
        agentverseView = defaults.string(forKey: Self.agentverseViewKey)
            .flatMap(AgentverseView.init(rawValue:)) ?? .office

        // `defaults.double` reports 0 for an absent key, and 0 is a real
        // latitude — the presence check is what keeps the equator from reading
        // as "the user typed something".
        manualLatitude = defaults.object(forKey: Self.manualLatitudeKey) as? Double
        manualLongitude = defaults.object(forKey: Self.manualLongitudeKey) as? Double
    }

    private func setOrRemove(_ value: Double?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
