import Foundation
import Security

protocol CredentialStore: Sendable {
    func save(secret: String, for reference: String) throws
    func readSecret(for reference: String) throws -> String?
    func deleteSecret(for reference: String) throws
}

protocol KeychainClient: Sendable {
    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(query: [String: Any]) -> OSStatus
    func copyMatching(query: [String: Any]) throws -> Data?
    func delete(query: [String: Any]) -> OSStatus
}

struct SystemKeychainClient: KeychainClient {
    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    func copyMatching(query: [String: Any]) throws -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return nil
            }
            throw KeychainError.status(status)
        }
        guard let data = item as? Data else {
            throw KeychainError.status(errSecInternalComponent)
        }
        return data
    }

    func delete(query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// `@unchecked` asserts exactly one thing: every access to `secrets` happens while `lock` is held.
/// That holds because `secrets` is private, the three methods below are its only accessors, and each
/// takes the lock for the whole access. No reference to `secrets` escapes the lock.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func save(secret: String, for reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[reference] = secret
    }

    func readSecret(for reference: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[reference]
    }

    func deleteSecret(for reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: reference)
    }
}

enum KeychainError: Error, Equatable {
    case status(OSStatus)
}

final class KeychainStore: CredentialStore, Sendable {
    private let service: String
    private let client: any KeychainClient

    init(
        service: String = "com.marcoscheffler.glyphline.credentials",
        client: any KeychainClient = SystemKeychainClient()
    ) {
        self.service = service
        self.client = client
    }

    func save(secret: String, for reference: String) throws {
        let data = Data(secret.utf8)
        let identityQuery = credentialIdentityQuery(for: reference)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = client.update(query: identityQuery, attributes: updateAttributes)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.status(updateStatus)
        }

        let addQuery = credentialAddQuery(for: reference, data: data)
        let addStatus = client.add(query: addQuery)
        guard addStatus == errSecSuccess else {
            throw KeychainError.status(addStatus)
        }
    }

    func readSecret(for reference: String) throws -> String? {
        let query = credentialReadQuery(for: reference)

        guard let data = try client.copyMatching(query: query) else {
            return nil
        }

        guard let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError.status(errSecInternalComponent)
        }
        return secret
    }

    func deleteSecret(for reference: String) throws {
        let query = credentialIdentityQuery(for: reference)
        let status = client.delete(query: query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private func credentialIdentityQuery(for reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference
        ]
    }

    private func credentialAddQuery(for reference: String, data: Data) -> [String: Any] {
        var query = credentialIdentityQuery(for: reference)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    private func credentialReadQuery(for reference: String) -> [String: Any] {
        var query = credentialIdentityQuery(for: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}
