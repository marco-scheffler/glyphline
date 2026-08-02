import Foundation

/// Deliberately not `Codable`.
///
/// `customName` is `private(set)` so that the rule about blank names — trimmed,
/// and nothing left of a blank means no name — runs on every way in. A
/// synthesised `init(from:)` is a way in that skips it: it assigns the stored
/// property straight from JSON, so a `"  "` in a decoded payload would become a
/// name the whole app then treats as real. Nothing decodes an `Account` today,
/// which made this a hole rather than a bug, and the conformance was unused —
/// the ledger persists through `AccountRecord`, which rebuilds accounts through
/// the initialiser and so is normalised on the way back out.
///
/// Should an `Account` ever need to be decoded, write `init(from:)` by hand and
/// route `customName` through `normalizedName`.
struct Account: Identifiable, Equatable, Sendable {
    let id: UUID
    var providerID: ProviderID
    /// The name derived from the credential when the account was added. Never
    /// empty, and never replaced: it is what the account falls back to once a
    /// user-chosen name is cleared.
    var displayName: String
    /// The user's own name for this account, when they gave one. Nil means they
    /// did not, or cleared it — the derived name then stands in.
    ///
    /// `private(set)` with `rename(to:)` as the only way in, so the rule that a
    /// blank name is no name is applied once rather than at every call site.
    private(set) var customName: String?
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
        claudeOrganizationID: String? = nil,
        customName: String? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.customName = Self.normalizedName(customName)
        self.credentialReference = credentialReference
        self.createdAt = createdAt
        self.isEnabled = isEnabled
        self.quotaCredentialReference = quotaCredentialReference
        self.claudeOrganizationID = claudeOrganizationID
    }

    /// The name to show, everywhere an account is named. The user's name when
    /// they gave one, the derived name otherwise — never empty, so no card,
    /// menu row or alert can end up nameless.
    var resolvedName: String {
        customName ?? displayName
    }

    /// Renames the account, or — passing nil or nothing but whitespace — clears
    /// the name and hands the account back to its derived one.
    mutating func rename(to name: String?) {
        customName = Self.normalizedName(name)
    }

    /// The one place the rule lives: trim, and treat what is left of a blank as
    /// no name at all. Written twice it would drift, and a stored `"  "` looks
    /// exactly like a real name to every reader.
    static func normalizedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
