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
}
