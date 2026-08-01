import XCTest
@testable import Glyphline

final class AppSettingsStoreTests: XCTestCase {
    func testAppModeRoundTripsThroughInjectedDefaults() {
        let suiteName = "GlyphlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        for mode in AppMode.allCases {
            let store = AppSettingsStore(defaults: defaults)
            store.appMode = mode

            let reloaded = AppSettingsStore(defaults: defaults)
            XCTAssertEqual(reloaded.appMode, mode)
        }
    }

    func testAppModeDefaultsToMenuBarAndWindow() {
        let suiteName = "GlyphlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.appMode, .menuBarAndWindow)
    }

    func testSyncSettingsDefaultToThirtyMinutesEnabled() {
        let suiteName = "sync-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertTrue(store.automaticSyncEnabled)
        XCTAssertEqual(store.syncIntervalMinutes, 30)
    }

    func testAgentverseViewRoundTripsThroughInjectedDefaults() {
        let suiteName = "agentverse-view-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        for view in AgentverseView.allCases {
            let store = AppSettingsStore(defaults: defaults)
            store.agentverseView = view

            let reloaded = AppSettingsStore(defaults: defaults)
            XCTAssertEqual(reloaded.agentverseView, view)
        }
    }

    func testAgentverseViewDefaultsToOffice() {
        let suiteName = "agentverse-view-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.agentverseView, .office)
    }

    /// A stored string outlives the case that wrote it: rename or remove a case
    /// in a later version and the old value is still sitting in the user's
    /// preferences on the next launch. Forcing it back into the enum would trap
    /// there, on a launch path, with no way out but deleting preferences.
    func testAgentverseViewFallsBackToOfficeForAnUnknownStoredValue() {
        let suiteName = "agentverse-view-unknown-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set("circuit", forKey: "agentverseView")

        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.agentverseView, .office)
    }

    func testManualPlaceRoundTripsAndClearingReturnsToTheTimeZone() {
        let suiteName = "manual-place-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fresh = AppSettingsStore(defaults: defaults)
        XCTAssertNil(fresh.placeOverride)

        fresh.manualLatitude = -33.87
        fresh.manualLongitude = 151.21

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.manualLatitude, -33.87)
        XCTAssertEqual(reloaded.manualLongitude, 151.21)
        let overridden = UserPlace.current(timeZone: TimeZone(identifier: "Europe/Berlin")!,
                                           override: reloaded.placeOverride)
        XCTAssertEqual(overridden.latitude, -33.87)
        XCTAssertEqual(overridden.longitude, 151.21)
        XCTAssertEqual(overridden.source, .manual)

        reloaded.manualLatitude = nil
        reloaded.manualLongitude = nil

        let cleared = AppSettingsStore(defaults: defaults)
        XCTAssertNil(cleared.manualLatitude)
        XCTAssertNil(cleared.manualLongitude)
        XCTAssertNil(cleared.placeOverride)
        let fromZone = UserPlace.current(timeZone: TimeZone(identifier: "Europe/Berlin")!,
                                         override: cleared.placeOverride)
        let expected = UserPlace.current(timeZone: TimeZone(identifier: "Europe/Berlin")!)
        XCTAssertEqual(fromZone, expected)
        XCTAssertNotEqual(fromZone.source, .manual)
    }

    /// Half an override is not an override: a latitude with no longitude would
    /// otherwise pair the user's latitude with a longitude of zero and light the
    /// office from Greenwich.
    func testHalfAManualPlaceIsNotAnOverride() {
        let suiteName = "manual-place-half-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = AppSettingsStore(defaults: defaults)
        store.manualLatitude = 52.52

        XCTAssertNil(store.placeOverride)
    }

    func testSyncSettingsPersist() {
        let suiteName = "sync-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let first = AppSettingsStore(defaults: defaults)
        first.automaticSyncEnabled = false
        first.syncIntervalMinutes = 60

        let second = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(second.automaticSyncEnabled)
        XCTAssertEqual(second.syncIntervalMinutes, 60)
    }
}
