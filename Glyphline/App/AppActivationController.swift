import AppKit

enum AppActivationController {
    @MainActor
    static func apply(mode: AppMode) {
        let policy: NSApplication.ActivationPolicy = mode == .menuBarOnly ? .accessory : .regular
        NSApp.setActivationPolicy(policy)
    }
}
