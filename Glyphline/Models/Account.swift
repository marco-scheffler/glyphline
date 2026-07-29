import Foundation

struct Account: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var providerID: ProviderID
    var displayName: String
    var credentialReference: String
    var createdAt: Date
    var isEnabled: Bool
    /// Points at the Keychain entry holding this account's quota token, when one
    /// exists. Separate from `credentialReference` because a single account can
    /// draw cost from a credential-free local source and quota from a token.
    var quotaCredentialReference: String?
    /// The organisation this account's claude.ai session belongs to. The usage
    /// endpoint's path contains it, so it has to be discovered once and kept.
    /// Nil for accounts that predate the web source or have not been resolved yet.
    var claudeOrganizationID: String?

    init(
        id: UUID,
        providerID: ProviderID,
        displayName: String,
        credentialReference: String,
        createdAt: Date,
        isEnabled: Bool,
        quotaCredentialReference: String? = nil,
        claudeOrganizationID: String? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.credentialReference = credentialReference
        self.createdAt = createdAt
        self.isEnabled = isEnabled
        self.quotaCredentialReference = quotaCredentialReference
        self.claudeOrganizationID = claudeOrganizationID
    }
}
