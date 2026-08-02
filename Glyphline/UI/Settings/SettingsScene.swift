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

    var body: some View {
        TabView {
            SettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.2") }
        }
        // A settings window sizes itself to its content, and the accounts tab is
        // a list that can be empty. Without a floor the window would open at the
        // size of an empty-state placeholder.
        .frame(minWidth: 640, minHeight: 520)
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

/// The accounts tab: the list, plus the ledger read that feeds it.
///
/// It loads for itself rather than being handed the dashboard's summaries. The
/// settings window and the dashboard window open independently — in
/// `.menuBarOnly` the dashboard never opens at all — so a list fed from the
/// dashboard's state would be empty exactly where it is the only way in.
struct AccountsSettingsView: View {
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
                onAdded: load
            )
        }
        .onAppear(perform: load)
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
