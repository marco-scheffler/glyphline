import SwiftUI

struct AddAccountView: View {
    private let ledgerStore: LedgerStore?
    /// Nil means the real window. Held rather than defaulted so the default is not
    /// evaluated outside the main actor, and so a caller can substitute one.
    private let signInPresenter: (any ClaudeSignInPresenting)?
    private let webSessions: any WebSessionRemoving
    private let onSave: () -> Void

    @State private var displayName = ""
    @State private var isEnabled = true
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saveError: String?

    init(
        ledgerStore: LedgerStore?,
        signInPresenter: (any ClaudeSignInPresenting)? = nil,
        webSessions: any WebSessionRemoving = ClaudeWebSessionStore(),
        onSave: @escaping () -> Void = {}
    ) {
        self.ledgerStore = ledgerStore
        self.signInPresenter = signInPresenter
        self.webSessions = webSessions
        self.onSave = onSave
    }

    var body: some View {
        Form {
            // No provider or source picker: a Claude subscription is the only
            // account that still produces anything — see `AddAccountFlow`.
            Section("Claude subscription") {
                TextField("Display Name", text: $displayName)
                Toggle("Enable account after save", isOn: $isEnabled)
            }

            Section("Data") {
                LabeledContent("Quality") {
                    Text(qualitySummary)
                        .foregroundStyle(.secondary)
                }

                Text(setupSummary)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Save Account") {
                        Task { await saveAccount() }
                    }
                    // Also while saving: a second tap during a web-session save
                    // would put a second sign-in window on screen.
                    .disabled(!canSave || isSaving)
                }

                if let saveMessage {
                    Text(saveMessage)
                        .foregroundStyle(.secondary)
                }

                if let saveError {
                    Text(saveError)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("Add Account")
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var qualitySummary: String {
        "Quota windows read from your own Claude subscription. No cost figures."
    }

    private var setupSummary: String {
        """
        Saving opens a window where you sign in to Claude. The session stays in this \
        subscription's own browser storage — no key or cookie is stored — and the account \
        is only added once the sign-in works. Cost comes from the Claude Code logs on this Mac.
        """
    }

    private func saveAccount() async {
        saveMessage = nil
        saveError = nil

        guard let ledgerStore else {
            saveError = "Ledger unavailable."
            return
        }

        isSaving = true
        defer { isSaving = false }

        // The save takes as long as a sign-in does, and the form would otherwise
        // sit there looking stuck behind its own window.
        saveMessage = "Sign in to Claude in the window that just opened."

        let flow = AddAccountFlow(
            ledgerStore: ledgerStore,
            signIn: signInPresenter ?? ClaudeSignInWindowPresenter(),
            webSessions: webSessions
        )

        switch await flow.save(displayName: displayName, isEnabled: isEnabled) {
        case .saved:
            displayName = ""
            isEnabled = true
            saveMessage = "Account saved."
            onSave()
        case .failed(let message):
            saveMessage = nil
            saveError = message
        }
    }
}
