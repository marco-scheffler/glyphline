import SwiftUI

struct AddAccountView: View {
    let providers: [PlaceholderProviderOption]

    @State private var selectedProviderID: ProviderID = .openAI
    @State private var displayName = ""
    @State private var credentialValue = ""
    @State private var isEnabled = true

    private var selectedProvider: PlaceholderProviderOption {
        providers.first(where: { $0.providerID == selectedProviderID }) ?? providers[0]
    }

    var body: some View {
        Form {
            Section("Connection") {
                Picker("Provider", selection: $selectedProviderID) {
                    ForEach(providers) { provider in
                        Text(provider.providerID.displayName)
                            .tag(provider.providerID)
                    }
                }

                TextField("Display Name", text: $displayName)
                SecureField(selectedProvider.credentialLabel, text: $credentialValue)
                Toggle("Enable account after save", isOn: $isEnabled)
            }

            Section("What Glyphline Will Show") {
                LabeledContent("Quality") {
                    Text(selectedProvider.qualitySummary)
                        .foregroundStyle(.secondary)
                }

                Text(selectedProvider.setupSummary)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Save Account") {
                    }
                    .disabled(displayName.isEmpty || credentialValue.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("Add Account")
    }
}
