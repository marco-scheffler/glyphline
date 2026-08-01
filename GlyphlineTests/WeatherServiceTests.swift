import XCTest
@testable import Glyphline

/// Nothing here touches the network. The WMO mapping is a pure function and the
/// decoder runs against a body captured from the real API once, by hand — a test
/// that reached out to api.open-meteo.com would be slow, would fail on a train,
/// and would still not tell us anything the fixture does not.
final class WeatherServiceTests: XCTestCase {

    // MARK: - The WMO table

    func testClearCodes() {
        XCTAssertEqual(WeatherService.weather(forWMOCode: 0), .clear)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 1), .clear)
    }

    func testCloudCodes() {
        XCTAssertEqual(WeatherService.weather(forWMOCode: 2), .cloud)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 3), .cloud)
    }

    func testFogCodes() {
        XCTAssertEqual(WeatherService.weather(forWMOCode: 45), .fog)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 48), .fog)
    }

    /// The drizzle-to-rain band, asserted at both edges: 50 is not rain, 51 is,
    /// 67 is, 68 is not. An off-by-one at either end is exactly what this catches.
    func testDrizzleAndRainBand() {
        XCTAssertEqual(WeatherService.weather(forWMOCode: 51), .rain)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 61), .rain)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 67), .rain)
        for code in 51...67 {
            XCTAssertEqual(WeatherService.weather(forWMOCode: code), .rain, "code \(code)")
        }
        XCTAssertEqual(WeatherService.weather(forWMOCode: 50), .clear)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 68), .clear)
    }

    func testShowerBand() {
        XCTAssertEqual(WeatherService.weather(forWMOCode: 80), .rain)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 81), .rain)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 82), .rain)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 79), .clear)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 83), .clear)
    }

    func testThunderstormBand() {
        XCTAssertEqual(WeatherService.weather(forWMOCode: 95), .rain)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 96), .rain)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 99), .rain)
        for code in 95...99 {
            XCTAssertEqual(WeatherService.weather(forWMOCode: code), .rain, "code \(code)")
        }
        XCTAssertEqual(WeatherService.weather(forWMOCode: 94), .clear)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 100), .clear)
    }

    /// Snow is overcast, not rain. There is no snow preset, and rain's dark,
    /// low-diffuse light is the wrong picture of a snowy day.
    func testSnowIsOvercastRatherThanRain() {
        for code in 71...77 {
            XCTAssertEqual(WeatherService.weather(forWMOCode: code), .cloud, "code \(code)")
        }
        XCTAssertEqual(WeatherService.weather(forWMOCode: 85), .cloud)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 86), .cloud)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 70), .clear)
        XCTAssertEqual(WeatherService.weather(forWMOCode: 78), .clear)
    }

    func testUnknownCodesFallBackToClear() {
        for code in [-1, 4, 44, 49, 69, 87, 90, 200] {
            XCTAssertEqual(WeatherService.weather(forWMOCode: code), .clear, "code \(code)")
        }
    }

    // MARK: - Decoding

    /// Captured verbatim from
    /// `https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.40&current=weather_code`.
    /// Keeping the untouched body — including the fields we ignore — is the point:
    /// it proves the decoder tolerates the response as it actually arrives.
    private static let realResponseBody = """
    {"latitude":52.52,"longitude":13.4,"generationtime_ms":0.019073486328125,\
    "utc_offset_seconds":0,"timezone":"GMT","timezone_abbreviation":"GMT","elevation":30.0,\
    "current_units":{"time":"iso8601","interval":"seconds","weather_code":"wmo code"},\
    "current":{"time":"2026-08-01T10:00","interval":900,"weather_code":61}}
    """

    func testDecodesWeatherCodeFromRealResponse() throws {
        let data = Data(Self.realResponseBody.utf8)

        XCTAssertEqual(try WeatherService.weatherCode(from: data), 61)
        XCTAssertEqual(WeatherService.weather(forWMOCode: try WeatherService.weatherCode(from: data)), .rain)
    }

    /// A body we cannot read must throw. Returning a default would make an outage
    /// look like a clear sky, which is indistinguishable from real data.
    func testMalformedBodyThrows() {
        XCTAssertThrowsError(try WeatherService.weatherCode(from: Data("not json at all".utf8)))
        XCTAssertThrowsError(try WeatherService.weatherCode(from: Data("{}".utf8)))
        XCTAssertThrowsError(try WeatherService.weatherCode(from: Data(#"{"current":{"time":"x"}}"#.utf8)))
    }

    // MARK: - The request

    /// Coordinates are coarse on purpose and the query carries nothing else — no
    /// identifier, no extra field. A locale that writes decimals with a comma
    /// would produce a URL the API rejects, so the formatting is pinned too.
    func testRequestURLCarriesOnlyCoordinatesAndTheCurrentField() throws {
        let url = WeatherService.requestURL(latitude: 52.52, longitude: 13.4)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "api.open-meteo.com")
        XCTAssertEqual(components.path, "/v1/forecast")
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first { $0.name == "latitude" }?.value, "52.52")
        XCTAssertEqual(items.first { $0.name == "longitude" }?.value, "13.40")
        XCTAssertEqual(items.first { $0.name == "current" }?.value, "weather_code")
    }

    func testNegativeCoordinatesKeepTheirSign() {
        let url = WeatherService.requestURL(latitude: -33.87, longitude: -70.67)

        XCTAssertTrue(url.absoluteString.contains("latitude=-33.87"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("longitude=-70.67"), url.absoluteString)
    }

    func testFetchDecodesTheTransportResponse() async throws {
        let service = WeatherService { _ in Data(Self.realResponseBody.utf8) }

        let weather = try await service.fetch(latitude: 52.52, longitude: 13.4)

        XCTAssertEqual(weather, .rain)
    }

    // MARK: - Throttling and persistence

    @MainActor
    func testFirstRefreshStoresTheReadingAndItsTimestamp() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let service = WeatherService { _ in Data(Self.realResponseBody.utf8) }

        let weather = await service.refreshIfNeeded(settings: settings, latitude: 0, longitude: 0, now: now)

        XCTAssertEqual(weather, .rain)
        XCTAssertEqual(settings.lastWeather, .rain)
        XCTAssertEqual(settings.lastWeatherFetch, now)

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.lastWeather, .rain)
        XCTAssertEqual(reloaded.lastWeatherFetch, now)
    }

    /// Nothing persisted yet: the caller gets a value it can draw with, but the
    /// store stays empty so the next refresh still counts as the first.
    @MainActor
    func testNoStoredReadingReportsClearWithoutPersistingIt() {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(defaults: defaults)

        XCTAssertNil(settings.lastWeather)
        XCTAssertEqual(settings.currentWeather, .clear)
    }

    @MainActor
    func testSecondRefreshWithinTheHourMakesNoRequest() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let counter = RequestCounter()
        let service = WeatherService { _ in
            await counter.increment()
            return Data(Self.realResponseBody.utf8)
        }

        _ = await service.refreshIfNeeded(settings: settings, latitude: 0, longitude: 0, now: start)
        _ = await service.refreshIfNeeded(
            settings: settings,
            latitude: 0,
            longitude: 0,
            now: start.addingTimeInterval(3599)
        )

        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testRefreshAfterAnHourMakesAnotherRequest() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let counter = RequestCounter()
        let service = WeatherService { _ in
            await counter.increment()
            return Data(Self.realResponseBody.utf8)
        }

        _ = await service.refreshIfNeeded(settings: settings, latitude: 0, longitude: 0, now: start)
        _ = await service.refreshIfNeeded(
            settings: settings,
            latitude: 0,
            longitude: 0,
            now: start.addingTimeInterval(3600)
        )

        let count = await counter.value
        XCTAssertEqual(count, 2)
    }

    /// The user never sees a weather request fail. The last known sky stays on
    /// screen, and the timestamp stays where it was so the next attempt is free
    /// to try again.
    @MainActor
    func testFailedRequestKeepsThePreviousReading() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let good = WeatherService { _ in Data(Self.realResponseBody.utf8) }
        _ = await good.refreshIfNeeded(settings: settings, latitude: 0, longitude: 0, now: start)

        let failing = WeatherService { _ in throw URLError(.notConnectedToInternet) }
        let weather = await failing.refreshIfNeeded(
            settings: settings,
            latitude: 0,
            longitude: 0,
            now: start.addingTimeInterval(7200)
        )

        XCTAssertEqual(weather, .rain)
        XCTAssertEqual(settings.lastWeather, .rain)
        XCTAssertEqual(settings.lastWeatherFetch, start)
    }

    // MARK: - Helpers

    private static func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "GlyphlineTests.weather.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private actor RequestCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
