import AppKit
import SwiftUI

/// The content of the app's `Settings` scene: what used to be two rows in the
/// dashboard's sidebar.
///
/// Accounts belongs here rather than on the dashboard because what is left of it
/// is management — add, remove, re-authenticate — and that is configuration. The
/// daily "how are my accounts doing" question is answered by the dashboard's
/// quota cards, which show every account at once.
struct SettingsRootView: View {
    @EnvironmentObject private var settings: AppSettingsStore

    /// The narrowest the settings window is ever laid out at — see the floor on
    /// the frame below. Named so a layout test can measure against the number
    /// production enforces rather than against one somebody guessed.
    static let minimumContentWidth: CGFloat = 640

    var body: some View {
        TabView {
            SettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            // Its own tab rather than a fourth section in General: it is a grid
            // of swatches, and General is already three sections of controls
            // that all answer "how does Glyphline behave", not "how does it
            // look".
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.2") }
        }
        // A settings window sizes itself to its content, and the accounts tab is
        // a list that can be empty. Without a floor the window would open at the
        // size of an empty-state placeholder.
        .frame(minWidth: Self.minimumContentWidth, minHeight: 520)
        // The window says who it is, so nothing downstream has to guess from a
        // framework-internal identifier.
        .background(SettingsWindowClaim())
        // In `.menuBarOnly` the app runs as an accessory, and a window opened by
        // an accessory app never becomes key, has no Dock icon, and cannot be
        // reached again once it loses focus — from outside that looks exactly
        // like a menu entry that does nothing. Same three steps the agentverse
        // window takes, for the same reason.
        .onAppear {
            AppActivationController.regulariseForWindow()
            NSApp.activate(ignoringOtherApps: true)
        }
        // …and back to whatever the mode asks for once the window is gone.
        // `apply(mode:)` keeps the app regular while any window that needs it is
        // still on screen, so closing settings over an open agentverse does not
        // pull the Dock icon out from under it.
        .onDisappear {
            AppActivationController.apply(mode: settings.appMode)
        }
    }
}

/// A zero-sized view whose only job is to hand its `NSWindow` to
/// `AppActivationController`.
///
/// The alternative is matching `com_apple_SwiftUI_Settings_window`, which is
/// SwiftUI's own name for the window and not something Apple promises to keep.
/// This costs one invisible view and cannot be renamed.
private struct SettingsWindowClaim: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClaimingView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// `viewDidMoveToWindow` rather than `makeNSView`: a view has no window at
    /// the moment it is created, only once it is installed.
    private final class ClaimingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            AppActivationController.claimSettingsWindow(window)
        }
    }
}

/// The accounts tab: the list, plus the ledger read that feeds it.
///
/// It loads for itself rather than being handed the dashboard's summaries. The
/// settings window and the dashboard window open independently — in
/// `.menuBarOnly` the dashboard never opens at all — so a list fed from the
/// dashboard's state would be empty exactly where it is the only way in.
struct AccountsSettingsView: View {
    /// Injected by `GlyphlineApp` into the settings scene, the same coordinator
    /// every other surface reads. Held here rather than reached from
    /// `AccountsView.commitRename`, which tests call directly on a view that was
    /// never hosted — an environment object read there would trap.
    @EnvironmentObject private var coordinator: SyncCoordinator
    @State private var accounts: [AccountUsageSummary] = []
    @State private var loadError: String?

    private let ledgerStore: LedgerStore?

    init(ledgerStore: LedgerStore? = LedgerStore.makeDefault()) {
        self.ledgerStore = ledgerStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            }

            AccountsView(
                accounts: accounts,
                ledgerStore: ledgerStore,
                onDeleted: load,
                onAdded: load,
                onRenamed: accountRenamed
            )
        }
        .onAppear(perform: load)
    }

    /// A rename has to reach more than this list. The quota cards and the menu
    /// bar panel render from `SyncCoordinator.quotaStates`, which stamps the name
    /// when a sync builds it — so this reload alone left the old name everywhere
    /// else until the next network round trip.
    private func accountRenamed() {
        load()
        coordinator.refreshAccountNames()
    }

    /// Not private: the reload after a save or a delete is the wiring that keeps
    /// a freshly added account from staying invisible, and it is worth asserting
    /// without driving the window.
    func load() {
        guard let ledgerStore else {
            loadError = "Ledger unavailable."
            accounts = []
            return
        }

        do {
            accounts = try ledgerStore.fetchAccountSummaries()
            loadError = nil
        } catch {
            accounts = []
            loadError = "Could not load ledger data."
        }
    }
}
