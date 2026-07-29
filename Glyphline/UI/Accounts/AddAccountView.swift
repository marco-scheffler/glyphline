import SwiftUI

struct AddAccountView: View {
    private let ledgerStore: LedgerStore?
    private let credentialStore: any CredentialStore
    /// Nil means the real window. Held rather than defaulted so the default is not
    /// evaluated outside the main actor, and so a caller can substitute one.
    private let signInPresenter: (any ClaudeSignInPresenting)?
    private let webSessions: any WebSessionRemoving
    private let onSave: () -> Void

    @State private var selectedProviderID: ProviderID = .openAI
    @State private var displayName = ""
    @State private var credentialValue = ""
    @State private var isEnabled = true
    @State private var selectedSource: AccountSource = .credential
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saveError: String?

    init(
        ledgerStore: LedgerStore? = LedgerStore.makeDefault(),
        credentialStore: any CredentialStore = KeychainStore(),
        signInPresenter: (any ClaudeSignInPresenting)? = nil,
        webSessions: any WebSessionRemoving = ClaudeWebSessionStore(),
        onSave: @escaping () -> Void = {}
    ) {
        self.ledgerStore = ledgerStore
        self.credentialStore = credentialStore
        self.signInPresenter = signInPresenter
        self.webSessions = webSessions
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Connection") {
                Picker("Provider", selection: $selectedProviderID) {
                    ForEach(ProviderID.allCases, id: \.self) { provider in
                        Text(provider.displayName)
                            .tag(provider)
                    }
                }
                .onChange(of: selectedProviderID) { _, newValue in
                    if newValue != .claude {
                        selectedSource = .credential
                    }
                }

                if selectedProviderID == .claude {
                    Picker("Source", selection: $selectedSource) {
                        Text("Admin API key").tag(AccountSource.credential)
                        Text("Local Claude Code logs").tag(AccountSource.localLogs)
                        Text("Claude subscription (sign in)").tag(AccountSource.claudeWebSession)
                    }
                    .pickerStyle(.radioGroup)
                }

                TextField("Display Name", text: $displayName)
                if effectiveSource == .credential {
                    SecureField(credentialLabel, text: $credentialValue)
                }
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

    /// The source picker only exists for Claude, so a selection left over from a
    /// provider switch decides nothing for anyone else. `AddAccountFlow` applies
    /// the same rule; the form asks the same question so what it shows and what it
    /// saves cannot disagree.
    private var effectiveSource: AccountSource {
        selectedProviderID == .claude ? selectedSource : .credential
    }

    private var canSave: Bool {
        let hasName = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasName && (effectiveSource != .credential || !credentialValue.isEmpty)
    }

    private var credentialLabel: String {
        switch selectedProviderID {
        case .openAI:
            return "API key"
        case .cursor:
            return "Session or team API credential"
        case .claude:
            return "Admin API key"
        }
    }

    private var qualitySummary: String {
        switch selectedProviderID {
        case .openAI:
            return "Exact usage and provider-reported API cost where available."
        case .cursor:
            return "Exact team API usage or partial local status until API access is configured."
        case .claude:
            // Only the web session gets its own sentence. The other two keep the
            // copy they had; widening that is a separate job.
            if selectedSource == .claudeWebSession {
                return "Quota windows read from your own Claude subscription. No cost figures."
            }
            return "Exact admin API data where available, otherwise capability-only state."
        }
    }

    private var setupSummary: String {
        switch selectedProviderID {
        case .openAI:
            return "The credential is stored in Keychain and the ledger stores only its reference."
        case .cursor:
            return "You can add multiple Cursor accounts or teams; each credential receives its own Keychain reference."
        case .claude:
            if selectedSource == .claudeWebSession {
                return """
                    Saving opens a window where you sign in to Claude. The session stays in this \
                    subscription's own browser storage — no key or cookie is stored — and the account \
                    is only added once the sign-in works. Cost stays with your Claude Code logs account.
                    """
            }
            return "Claude admin credentials unlock usage and billing-period metadata when the provider exposes it."
        }
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

        if effectiveSource == .claudeWebSession {
            // The save can now take as long as a sign-in does, and the form would
            // otherwise sit there looking stuck behind its own window.
            saveMessage = "Sign in to Claude in the window that just opened."
        }

        let flow = AddAccountFlow(
            ledgerStore: ledgerStore,
            credentialStore: credentialStore,
            signIn: signInPresenter ?? ClaudeSignInWindowPresenter(),
            webSessions: webSessions
        )

        switch await flow.save(
            providerID: selectedProviderID,
            displayName: displayName,
            source: selectedSource,
            credentialValue: credentialValue,
            isEnabled: isEnabled
        ) {
        case .saved:
            displayName = ""
            credentialValue = ""
            isEnabled = true
            selectedSource = .credential
            saveMessage = "Account saved."
            onSave()
        case .failed(let message):
            saveMessage = nil
            saveError = message
        }
    }
}
