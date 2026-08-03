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

    func testAppModeDefaultsToMenuBarOnly() {
        let suiteName = "GlyphlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.appMode, .menuBarOnly)
    }

    /// Upgrading from 1.4. `menuBarAndWindow` is no longer a case, so its stored
    /// string no longer parses and falls to the default — which is the new menu
    /// bar default. No migration code: the fallback already does it, and this
    /// test is what keeps that true if the fallback is ever changed.
    func testAStoredMenuBarAndWindowReadsBackAsMenuBarOnly() {
        let suiteName = "GlyphlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("menuBarAndWindow", forKey: "appMode")

        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.appMode, .menuBarOnly)
    }

    /// A deliberate `windowOnly` survives the upgrade untouched.
    func testAStoredWindowOnlySurvivesTheUpgrade() {
        let suiteName = "GlyphlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("windowOnly", forKey: "appMode")

        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.appMode, .windowOnly)
    }

    /// The first-launch exception belongs to the installation, not to the mode:
    /// a fresh install shows the dashboard once so that launching a newly
    /// installed app is not an empty screen and an unfamiliar menu bar symbol.
    func testAFreshInstallOpensTheDashboardOnceAndThenStops() {
        let suiteName = "GlyphlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(fresh.hasShownDashboardOnce)
        XCTAssertTrue(fresh.opensDashboardAtLaunch)

        fresh.hasShownDashboardOnce = true

        let later = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(later.hasShownDashboardOnce)
        XCTAssertFalse(later.opensDashboardAtLaunch)
    }

    /// `windowOnly` opens it every time regardless of the flag.
    func testWindowOnlyOpensTheDashboardEveryLaunch() {
        let suiteName = "GlyphlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppSettingsStore(defaults: defaults)
        store.appMode = .windowOnly
        store.hasShownDashboardOnce = true

        XCTAssertTrue(store.opensDashboardAtLaunch)
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
