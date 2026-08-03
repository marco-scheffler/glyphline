import XCTest
@testable import Glyphline

/// The schedule used to be applied from a view's `onAppear`. It now lives in
/// `SyncScheduleController`, and these tests pin the one thing that can break
/// there without breaking anything else: the sink must read the values Combine
/// hands it, not the values still sitting in the store.
@MainActor
final class SyncScheduleControllerTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "GlyphlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    /// Never returns, so the scheduler loop parks in its first sleep instead of
    /// spinning through collections while the test looks at the schedule.
    private func makeCoordinator() -> SyncCoordinator {
        SyncCoordinator(
            ledger: nil,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            sleepForSeconds: { _ in
                try await Task.sleep(for: .seconds(3_600))
            }
        )
    }

    /// `combineLatest` emits once on subscription, so constructing the
    /// controller is the initial application. There is no separate `apply()`,
    /// and this is what would fail if the subscription were made lazy.
    func testConstructingTheControllerAppliesTheCurrentSettings() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        settings.automaticSyncEnabled = true
        settings.syncIntervalMinutes = 15
        let coordinator = makeCoordinator()

        let controller = SyncScheduleController(settings: settings, coordinator: coordinator)
        withExtendedLifetime(controller) {
            XCTAssertTrue(coordinator.isSchedulerRunning)
            XCTAssertEqual(coordinator.currentIntervalSeconds, 900)
        }
    }

    /// The regression this file exists for. `@Published` publishes on `willSet`,
    /// so a sink that read `settings.automaticSyncEnabled` instead of the value
    /// Combine passed it would see the value being replaced — the schedule would
    /// be one change behind forever, and every other test would stay green.
    func testTurningAutomaticSyncOffStopsTheSchedulerRatherThanLaggingByOneChange() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        settings.automaticSyncEnabled = true
        settings.syncIntervalMinutes = 15
        let coordinator = makeCoordinator()

        let controller = SyncScheduleController(settings: settings, coordinator: coordinator)
        withExtendedLifetime(controller) {
            XCTAssertTrue(coordinator.isSchedulerRunning)

            settings.automaticSyncEnabled = false

            XCTAssertFalse(
                coordinator.isSchedulerRunning,
                "the sink must use the value Combine passed it, not the one still in the store"
            )
            XCTAssertNil(coordinator.currentIntervalSeconds)
        }
    }

    /// The same lag, in the other direction: switching automatic syncing back on
    /// has to start the loop, not re-apply the `false` that is being replaced.
    func testTurningAutomaticSyncOnStartsTheScheduler() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        settings.automaticSyncEnabled = false
        settings.syncIntervalMinutes = 20
        let coordinator = makeCoordinator()

        let controller = SyncScheduleController(settings: settings, coordinator: coordinator)
        withExtendedLifetime(controller) {
            XCTAssertFalse(coordinator.isSchedulerRunning)

            settings.automaticSyncEnabled = true

            XCTAssertTrue(coordinator.isSchedulerRunning)
            XCTAssertEqual(coordinator.currentIntervalSeconds, 1_200)
        }
    }

    /// The second input has to reach the coordinator too, and it has to arrive in
    /// seconds. An off-by-sixty here is invisible outside production.
    func testAnIntervalChangeReachesTheCoordinatorInSeconds() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        settings.automaticSyncEnabled = true
        settings.syncIntervalMinutes = 15
        let coordinator = makeCoordinator()

        let controller = SyncScheduleController(settings: settings, coordinator: coordinator)
        withExtendedLifetime(controller) {
            XCTAssertEqual(coordinator.currentIntervalSeconds, 900)

            settings.syncIntervalMinutes = 45

            XCTAssertEqual(
                coordinator.currentIntervalSeconds, 2_700,
                "the interval is minutes in the settings and seconds at the coordinator"
            )
        }
    }
}
