import Foundation

struct Account: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var providerID: ProviderID
    var displayName: String
    var credentialReference: String
    var createdAt: Date
    var isEnabled: Bool
}
