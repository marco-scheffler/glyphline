import SwiftUI

struct DashboardView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Text("Dashboard")
                Text("Accounts")
                Text("History")
                Text("Settings")
            }
            .navigationTitle("Glyphline")
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                Text("Glyphline")
                    .font(.largeTitle.bold())
                Text("Usage overview is ready for provider adapters.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}
