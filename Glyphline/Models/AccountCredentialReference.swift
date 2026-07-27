import Foundation

/// Builds the credential reference stored on an account.
///
/// The reference is a pointer, never a secret: the Keychain form names the
/// account whose secret to look up, and the local form names no secret at all.
///
/// The reference is also the signal the adapter registry reads to choose between
/// a credentialed API and a local, credential-free source.
enum AccountCredentialReference {
    static func make(accountID: UUID, usesLocalSource: Bool) -> String {
        usesLocalSource
            ? "\(ProviderAdapterRegistry.localSourceScheme)\(accountID.uuidString)"
            : "keychain://glyphline/\(accountID.uuidString)"
    }
}
