import SwiftUI

struct AddAccountView: View {
    private let ledgerStore: LedgerStore?
    private let credentialStore: any CredentialStore
    private let onSave: () -> Void

    @State private var selectedProviderID: ProviderID = .openAI
    @State private var displayName = ""
    @State private var credentialValue = ""
    @State private var isEnabled = true
    @State private var usesLocalSource = false
    @State private var saveMessage: String?
    @State private var saveError: String?

    init(
        ledgerStore: LedgerStore? = LedgerStore.makeDefault(),
        credentialStore: any CredentialStore = KeychainStore(),
        onSave: @escaping () -> Void = {}
    ) {
        self.ledgerStore = ledgerStore
        self.credentialStore = credentialStore
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
                        usesLocalSource = false
                    }
                }

                if selectedProviderID == .claude {
                    Picker("Source", selection: $usesLocalSource) {
                        Text("Admin API key").tag(false)
                        Text("Local Claude Code logs").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                }

                TextField("Display Name", text: $displayName)
                if !usesLocalSource {
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
                    Button("Save Account", action: saveAccount)
                        .disabled(!canSave)
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
        let hasName = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasName && (usesLocalSource || !credentialValue.isEmpty)
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
            return "Claude admin credentials unlock usage and billing-period metadata when the provider exposes it."
        }
    }

    private func saveAccount() {
        saveMessage = nil
        saveError = nil

        guard let ledgerStore else {
            saveError = "Ledger unavailable."
            return
        }

        let accountID = UUID()
        let usesLocal = usesLocalSource && selectedProviderID == .claude
        let reference = AccountCredentialReference.make(accountID: accountID, usesLocalSource: usesLocal)
        let account = Account(
            id: accountID,
            providerID: selectedProviderID,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialReference: reference,
            createdAt: Date(),
            isEnabled: isEnabled
        )

        do {
            if !usesLocal {
                try credentialStore.save(secret: credentialValue, for: reference)
            }
            do {
                try ledgerStore.saveAccount(account)
            } catch {
                if !usesLocal {
                    try? credentialStore.deleteSecret(for: reference)
                }
                throw error
            }

            displayName = ""
            credentialValue = ""
            isEnabled = true
            usesLocalSource = false
            saveMessage = "Account saved."
            onSave()
        } catch {
            saveError = "Could not save account."
        }
    }
}
