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
