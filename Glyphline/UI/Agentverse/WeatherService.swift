import Foundation

/// What the sky is doing where the user is, so the office windows show their
/// weather rather than a permanently sunny one.
///
/// Open-Meteo needs no key and no account, and the request carries nothing but
/// the two coordinates `UserPlace` produced — which are already coarse, a
/// timezone's representative city rather than a device fix — and the one field
/// we read. This is the app's first outbound request unrelated to the user's own
/// accounts, and keeping it that thin is the whole point: there is nothing in it
/// that could identify anyone, and nothing to be gained by adding precision.
struct WeatherService: Sendable {
    /// How the bytes are fetched.
    ///
    /// A closure rather than a stored `URLSession` because it keeps the type
    /// `Sendable` without any escape hatch, and because it lets the tests pin the
    /// mapping and the throttle without ever reaching the network.
    typealias Transport = @Sendable (URL) async throws -> Data

    /// At most one request an hour, and only while the Agentverse window is open
    /// — nothing about the sky is worth waking the machine for.
    static let minimumInterval: TimeInterval = 3600

    private let transport: Transport

    init(transport: @escaping Transport = WeatherService.urlSessionTransport) {
        self.transport = transport
    }

    /// The default transport. `URLSession.shared.data(from:)` already hands back
    /// `Data`, which is `Sendable`, so nothing crosses the boundary that needs an
    /// exception.
    static let urlSessionTransport: Transport = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WeatherServiceError.httpStatus(http.statusCode)
        }
        return data
    }

    // MARK: - Fetching

    func fetch(latitude: Double, longitude: Double) async throws -> Weather {
        let data = try await transport(Self.requestURL(latitude: latitude, longitude: longitude))
        return Self.weather(forWMOCode: try Self.weatherCode(from: data))
    }

    /// The sky to draw with, refreshed at most once an hour.
    ///
    /// A failure is not something the user sees: the previously stored reading
    /// stays, and the timestamp is left alone so the next call may try again
    /// immediately rather than waiting out an hour it never got an answer for.
    ///
    /// `@MainActor` because `AppSettingsStore` is an `ObservableObject` owned by
    /// the view layer; hopping back to it after the `await` is what makes writing
    /// to it safe under strict concurrency, with no `@unchecked` anywhere.
    @MainActor
    func refreshIfNeeded(
        settings: AppSettingsStore,
        latitude: Double,
        longitude: Double,
        now: Date = Date()
    ) async -> Weather {
        if let last = settings.lastWeatherFetch,
           now.timeIntervalSince(last) < Self.minimumInterval,
           now >= last {
            return settings.currentWeather
        }

        do {
            let weather = try await fetch(latitude: latitude, longitude: longitude)
            settings.lastWeather = weather
            settings.lastWeatherFetch = now
            return weather
        } catch {
            return settings.currentWeather
        }
    }

    // MARK: - The request

    static func requestURL(latitude: Double, longitude: Double) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        // Two decimals is about a kilometre — far finer than the city-level input
        // already is, and the API rejects anything that is not a plain decimal, so
        // `String(format:)` (which is POSIX, not locale-aware) rather than a
        // formatter that would write "52,52" for a German user.
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "weather_code")
        ]
        // The components are all constants or formatted numbers, so this cannot
        // fail; force-unwrapping keeps a non-failable signature at the call sites.
        return components.url!
    }

    // MARK: - Decoding

    private struct Response: Decodable {
        struct Current: Decodable {
            let weatherCode: Int

            enum CodingKeys: String, CodingKey {
                case weatherCode = "weather_code"
            }
        }

        let current: Current
    }

    /// Throws on anything it cannot read. A default here would be worse than no
    /// value at all: an outage would render as a clear sky and look like data.
    static func weatherCode(from data: Data) throws -> Int {
        try JSONDecoder().decode(Response.self, from: data).current.weatherCode
    }

    // MARK: - The WMO table

    /// WMO 4677 weather codes, as Open-Meteo reports them, collapsed onto the
    /// four presets the scene lighting has.
    static func weather(forWMOCode code: Int) -> Weather {
        switch code {
        case 0, 1:
            return .clear
        case 2, 3:
            return .cloud
        case 45, 48:
            return .fog
        // Drizzle, rain and freezing rain; showers; thunderstorms.
        case 51...67, 80...82, 95...99:
            return .rain
        // Snow and snow showers. There is no snow preset, and rain's dark, wet
        // light is the wrong picture of a snowy day — overcast is much closer.
        case 71...77, 85, 86:
            return .cloud
        default:
            // Includes codes the WMO leaves unassigned and anything a future API
            // version might add: an unknown sky is drawn as an ordinary one.
            return .clear
        }
    }
}

enum WeatherServiceError: Error, Equatable {
    case httpStatus(Int)
}
