import Foundation

/// What the dashboard and menu bar render for one account's sync.
enum SyncActivity: Equatable, Sendable {
    case idle
    case running(phase: String)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
