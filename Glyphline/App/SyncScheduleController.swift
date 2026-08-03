import Combine
import Foundation

/// Keeps the coordinator's sync schedule in step with the settings.
///
/// App-level rather than attached to a view, because the view it used to be
/// attached to is now suppressed at launch in the default mode. Automatic
/// syncing would never start, and nothing would say so — the app would look
/// like it was working, with figures that quietly stopped moving.
///
/// `combineLatest` emits once on subscription with both current values, so the
/// initial application and every later change are the same code path rather than
/// an `apply()` call that can drift from the observer beside it.
@MainActor
final class SyncScheduleController {
    private var cancellable: AnyCancellable?

    init(settings: AppSettingsStore, coordinator: SyncCoordinator) {
        cancellable = settings.$automaticSyncEnabled
            .combineLatest(settings.$syncIntervalMinutes)
            .sink { enabled, minutes in
                MainActor.assumeIsolated {
                    // The coordinator ignores a re-application of the schedule
                    // it is already running, so a repeated emission cannot push
                    // the next sync out by another full interval.
                    coordinator.applySchedule(
                        enabled: enabled,
                        intervalSeconds: TimeInterval(minutes * 60)
                    )
                }
            }
    }
}
