import XCTest
@testable import Glyphline

/// The schedule used to be applied from a view's `onAppear`. It now lives in
/// `SyncScheduleController`, and these tests pin the one thing that can break
/// there without breaking anything else: the sink must read the values Combine
/// hands it, not the values still sitting in the store.
///
/// Every test below asserts on the coordinator immediately after assigning to a
/// setting, which assumes the sink runs synchronously on the assigning call
/// stack. That holds because the chain in `SyncScheduleController` is
/// `$a.combineLatest($b).sink` and nothing else. Adding a `receive(on:)`, a
/// `debounce` or a `throttle` there would take these tests red for a reason the
/// failure text will not mention — the assertions would be reading the schedule
/// before the sink has run, not reading a wrong schedule.
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

    /// `sleepForSeconds` never returns, so the scheduler loop parks in its first
    /// sleep instead of spinning through collections while the test looks at the
    /// schedule. The teardown stops it again: releasing the controller cancels
    /// the subscription but not the coordinator's task, which would otherwise sit
    /// in that sleep for the rest of the test process.
    private func makeCoordinator() -> SyncCoordinator {
        let coordinator = SyncCoordinator(
            ledger: nil,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            sleepForSeconds: { _ in
                try await Task.sleep(for: .seconds(3_600))
            }
        )
        addTeardownBlock { @MainActor in
            coordinator.stopScheduler()
        }
        return coordinator
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
            XCTAssertTrue(
                coordinator.isSchedulerRunning,
                "constructing the controller must subscribe and apply at once; a scheduler that is not running here means the first emission never arrived"
            )
            XCTAssertEqual(
                coordinator.currentIntervalSeconds, 900,
                "the first emission must carry the settings as they stand, not a later change"
            )
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
            XCTAssertTrue(
                coordinator.isSchedulerRunning,
                "precondition: the schedule has to be running before switching it off can mean anything"
            )

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
    ///
    /// Deliberately kept even though no edit reddens it alone — it is the mirror
    /// of the test above, and it is the direction a user actually notices,
    /// because a schedule that fails to start looks exactly like an app with
    /// nothing to report. It is a second reading of one guard, not a fourth one.
    func testTurningAutomaticSyncOnStartsTheScheduler() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        settings.automaticSyncEnabled = false
        settings.syncIntervalMinutes = 20
        let coordinator = makeCoordinator()

        let controller = SyncScheduleController(settings: settings, coordinator: coordinator)
        withExtendedLifetime(controller) {
            XCTAssertFalse(coordinator.isSchedulerRunning)

            settings.automaticSyncEnabled = true

            XCTAssertTrue(
                coordinator.isSchedulerRunning,
                "switching automatic syncing on must start the loop, not re-apply the false being replaced"
            )
            XCTAssertEqual(
                coordinator.currentIntervalSeconds, 1_200,
                "the interval must come along with the enabling emission"
            )
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

    /// Both inputs are re-sent on every emission, so an interval change while
    /// automatic syncing is off must not be read as a reason to start.
    func testAnIntervalChangeWhileAutomaticSyncIsOffLeavesTheSchedulerStopped() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        settings.automaticSyncEnabled = false
        settings.syncIntervalMinutes = 15
        let coordinator = makeCoordinator()

        let controller = SyncScheduleController(settings: settings, coordinator: coordinator)
        withExtendedLifetime(controller) {
            settings.syncIntervalMinutes = 45

            XCTAssertFalse(
                coordinator.isSchedulerRunning,
                "an interval change is not a reason to start a schedule the user has switched off"
            )
            XCTAssertNil(coordinator.currentIntervalSeconds)
        }
    }
}
