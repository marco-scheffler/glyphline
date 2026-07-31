import XCTest
@testable import Glyphline

/// The arithmetic that can be wrong while the scene still looks right.
///
/// A slider position converted the wrong way round through the circuit's zone
/// produces a plausibly lit picture that is off by the zone's offset — nine
/// hours at Suzuka. Nothing on screen says so, so it is asserted here.
final class CircuitClockTests: XCTestCase {
    /// Midday UTC on a June day, well clear of every daylight-saving changeover
    /// — and midday rather than midnight so that every circuit here is on the
    /// same calendar day. Midnight UTC puts Nevada on the day before Japan, and
    /// two circuits at "noon" would then legitimately be a day apart.
    private let reference = Date(timeIntervalSince1970: 1_781_611_200)

    private func circuit(_ key: String) throws -> Circuit {
        try XCTUnwrap(CircuitCatalog.bundled().circuit(key))
    }

    /// The whole point of the feature: the same slider position is a different
    /// instant at two circuits, by exactly the real offset between their zones.
    func testTheSameLocalTimeIsADifferentInstantAtSuzukaAndLasVegas() throws {
        let suzuka = try circuit("suzuka")
        let vegas = try circuit("vegas")
        let atNoon = 12 * 60.0

        let suzukaInstant = CircuitClock.instant(for: suzuka, minutesOfLocalDay: atNoon,
                                                 on: reference)
        let vegasInstant = CircuitClock.instant(for: vegas, minutesOfLocalDay: atNoon,
                                                on: reference)

        let suzukaZone = try XCTUnwrap(CircuitClock.timeZone(for: suzuka))
        let vegasZone = try XCTUnwrap(CircuitClock.timeZone(for: vegas))
        let expected = Double(suzukaZone.secondsFromGMT(for: suzukaInstant)
                              - vegasZone.secondsFromGMT(for: vegasInstant))

        XCTAssertGreaterThan(expected, 0, "Suzuka reaches noon before Las Vegas does")
        XCTAssertEqual(vegasInstant.timeIntervalSince(suzukaInstant), expected, accuracy: 1,
                       "noon at Suzuka and noon in Nevada must be the zones' offset apart")
    }

    /// The direction check on its own: noon at the circuit reads back as noon at
    /// the circuit, not as noon anywhere else.
    func testAnInstantReadsBackAsTheLocalTimeItWasBuiltFrom() throws {
        for key in try CircuitCatalog.bundled().entriesInPickerOrder.map(\.key) {
            let circuit = try self.circuit(key)
            for minutes: Double in [0, 360, 720, 1_080, 1_410] {
                let instant = CircuitClock.instant(for: circuit, minutesOfLocalDay: minutes,
                                                   on: reference)
                XCTAssertEqual(CircuitClock.minutesOfLocalDay(for: circuit, at: instant),
                               minutes, accuracy: 1.0 / 60,
                               "\(key) at \(minutes) minutes past local midnight")
            }
        }
    }

    /// The conversion could be self-consistent and still light the scene from
    /// the wrong side of the planet, so the sun itself is asked: at local noon it
    /// must be near its highest for that day, at every circuit.
    func testTheSunIsNearItsDailyPeakAtLocalNoonOnEveryCircuit() throws {
        for key in try CircuitCatalog.bundled().entriesInPickerOrder.map(\.key) {
            let circuit = try self.circuit(key)
            func elevation(atLocalMinutes minutes: Double) -> Double {
                SunPosition.at(latitude: circuit.lat, longitude: circuit.lon,
                               date: CircuitClock.instant(for: circuit,
                                                          minutesOfLocalDay: minutes,
                                                          on: reference)).elevation
            }

            let noon = elevation(atLocalMinutes: 12 * 60)
            let peak = stride(from: 0.0, through: CircuitClock.minutesPerDay, by: 10)
                .map(elevation(atLocalMinutes:))
                .max() ?? noon

            // Not equality: a zone is an hour wide only nominally, and Nevada
            // sits far enough west in its own that solar noon there is nearly an
            // hour after the clock says twelve. Ten degrees is loose enough for
            // that and nowhere near loose enough for an offset error — being out
            // by one hour of longitude alone costs more than that at Suzuka.
            XCTAssertGreaterThan(noon, peak - 10,
                                 "\(key): the sun at local noon must be near its daily peak")
            XCTAssertGreaterThan(noon, elevation(atLocalMinutes: 0),
                                 "\(key): noon must be brighter than local midnight")
        }
    }

    /// Every bundled circuit names a zone this system knows. If one stops doing
    /// so the fallback below takes over silently, and this is the only thing
    /// that would say why the clock moved.
    func testEveryBundledCircuitNamesARecognisedTimeZone() throws {
        for key in try CircuitCatalog.bundled().entriesInPickerOrder.map(\.key) {
            let circuit = try self.circuit(key)
            XCTAssertNotNil(CircuitClock.timeZone(for: circuit),
                            "\(key) carries the unusable identifier \(circuit.tz)")
        }
    }

    /// An unrecognised identifier must never resolve to the viewer's own zone: a
    /// scene lit by the wrong continent's clock looks correct and is wrong.
    func testAnUnrecognisedTimeZoneFallsBackToUTCAndSaysSo() throws {
        var circuit = try self.circuit("suzuka")
        circuit.tz = "Mars/Olympus_Mons"

        XCTAssertNil(CircuitClock.timeZone(for: circuit))
        let resolved = CircuitClock.resolvedTimeZone(for: circuit)
        XCTAssertTrue(resolved.isFallback)
        XCTAssertEqual(resolved.zone.secondsFromGMT(for: reference), 0)
        XCTAssertTrue(CircuitClock.localTimeText(for: circuit, at: reference).hasSuffix("UTC"),
                      "a UTC clock must not pass for the circuit's local time")
    }

    /// The slider cannot ask for an instant outside the day it spans.
    func testTheLocalDayIsTheSliderSFullRange() throws {
        let circuit = try self.circuit("monaco")
        let midnight = CircuitClock.instant(for: circuit, minutesOfLocalDay: 0, on: reference)
        let end = CircuitClock.instant(for: circuit,
                                       minutesOfLocalDay: CircuitClock.minutesPerDay,
                                       on: reference)

        XCTAssertEqual(end.timeIntervalSince(midnight), 86_400, accuracy: 1)
    }
}

final class WeatherChoiceTests: XCTestCase {
    /// "On location" is the default and, until a real report is wired up, clear.
    /// It is a case of its own rather than a second spelling of clear, so this
    /// pins both halves of that.
    func testOnLocationIsOfferedFirstAndIsClearForNow() {
        XCTAssertEqual(WeatherChoice.allCases.first, .onLocation)
        XCTAssertEqual(WeatherChoice.onLocation.weather, .clear)
        XCTAssertNotEqual(WeatherChoice.onLocation, .fixed(.clear))
        XCTAssertEqual(WeatherChoice.allCases.count, Weather.allCases.count + 1)
    }

    func testEveryWeatherIsOffered() {
        for weather in Weather.allCases {
            XCTAssertTrue(WeatherChoice.allCases.contains(.fixed(weather)))
            XCTAssertEqual(WeatherChoice.fixed(weather).weather, weather)
        }
    }
}
